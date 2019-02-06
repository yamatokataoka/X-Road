#
# The MIT License
# Copyright (c) 2018 Estonian Information System Authority (RIA),
# Nordic Institute for Interoperability Solutions (NIIS), Population Register Centre (VRK)
# Copyright (c) 2015-2017 Estonian Information System Authority (RIA), Population Register Centre (VRK)
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in
# all copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
# THE SOFTWARE.
#

require 'thread'

java_import Java::ee.ria.xroad.common.SystemProperties
java_import Java::ee.ria.xroad.common.request.ClientRegRequestStatusWrapper
java_import Java::ee.ria.xroad.common.request.ManagementRequestHandler
java_import Java::ee.ria.xroad.common.request.ManagementRequestParser
java_import Java::ee.ria.xroad.common.request.ManagementRequestUtil
java_import Java::ee.ria.xroad.common.request.ManagementRequests
java_import Java::ee.ria.xroad.common.message.SoapUtils
java_import Java::ee.ria.xroad.common.message.SoapFault
java_import Java::ee.ria.xroad.common.ErrorCodes
java_import Java::ee.ria.xroad.common.CodedException

class ManagementRequestsController < ApplicationController
  @@auth_cert_registration_mutex = Mutex.new
  @@client_registration_mutex = Mutex.new

  def create
    begin
      response.content_type = "text/xml"

      @xroad_instance = SystemParameter.instance_identifier
      raise "X-Road instance must exist!" if @xroad_instance.blank?

      @client_reg_request_status_wrapper = ClientRegRequestStatusWrapper.new

      @request_soap = ManagementRequestHandler.readRequest(
        request.headers["CONTENT_TYPE"],
        StringIO.new(request.raw_post).to_inputstream,
        @client_reg_request_status_wrapper)

      id = handle_request
      logger.debug("Created request id: #{id}")

      # Simply convert request message to response message
      response_soap = ManagementRequestUtil.toResponse(@request_soap, id)

      render :text => response_soap.getXml()
    rescue Java::java.lang.Exception => e
      handle_error(ErrorCodes.translateException(e))
    rescue Exception => e
      handle_error(CodedException.new(ErrorCodes::X_INTERNAL_ERROR, e.message))
      logger.error("Internal error: #{e.message}\n#{e.backtrace.join("\n\t")}")
    end
  end

  private

  def handle_request
    service = @request_soap.getService().getServiceCode()
    case service
    when ManagementRequests::AUTH_CERT_REG
      handle_auth_cert_registration
    when ManagementRequests::AUTH_CERT_DELETION
      handle_auth_cert_deletion
    when ManagementRequests::CLIENT_REG
      handle_client_registration
    when ManagementRequests::CLIENT_DELETION
      handle_client_deletion
    else
      raise "Unknown service code '#{service}'"
    end
  end

  def handle_error(ex)
    render :text => SoapFault.createFaultXml(ex)
  end

  def handle_auth_cert_registration
    req_type = ManagementRequestParser.parseAuthCertRegRequest(@request_soap)
    security_server = security_server_id(req_type.getServer())

    verify_xroad_instance(security_server)
    verify_owner(security_server)

    req = nil
    auth_cert_reg_request = nil

    auth_cert_bytes = String.from_java_bytes(req_type.getAuthCert())

    @@auth_cert_registration_mutex.synchronize do
      req = AuthCertRegRequest.new(
        :security_server => security_server,
        :auth_cert => auth_cert_bytes,
        :address => req_type.getAddress(),
        :origin => Request::SECURITY_SERVER)
      req.register()

      if auto_approve_auth_cert_reg_requests?
        auth_cert_reg_request = AuthCertRegRequest.new(
          :security_server => security_server,
          :auth_cert => auth_cert_bytes,
          :address => req_type.getAddress(),
          :origin => Request::CENTER)
        auth_cert_reg_request.register()
      end
    end

    if auto_approve_auth_cert_reg_requests?
      RequestWithProcessing.approve(auth_cert_reg_request.id)
    end

    req.id
  end

  def handle_auth_cert_deletion
    req_type = ManagementRequestParser.parseAuthCertDeletionRequest(
      @request_soap)
    security_server = security_server_id(req_type.getServer())

    verify_xroad_instance(security_server)
    verify_owner(security_server)

    req = AuthCertDeletionRequest.new(
      :security_server => security_server,
      :auth_cert => String.from_java_bytes(req_type.getAuthCert()),
      :origin => Request::SECURITY_SERVER)
    req.register()
    req.id
  end

  def handle_client_registration
    req_type = ManagementRequestParser.parseClientRegRequest(@request_soap)
    security_server = security_server_id(req_type.getServer())
    server_user = client_id(req_type.getClient())

    verify_xroad_instance(security_server)
    verify_xroad_instance(server_user)

    verify_owner(security_server)

    req = nil
    client_reg_request = nil

    server_user_member = SecurityServerClient.find_by_id(member_id(req_type.getClient()))

    # Requests can be automatically approved when:
    # 1) auto approval is enabled;
    # 2) client registration request has been signed by the member owning the client to be added,
    #    and if signature and certificate have passed verification;
    # 3) member owning the subsystem exists on Central Server.
    auto_approve_and_request_verified_and_owner_exists = auto_approve_client_reg_requests? &&
                    @client_reg_request_status_wrapper.getClientRegRequestSignedAndVerified &&
                    !server_user_member.nil?

    @@client_registration_mutex.synchronize do
      req = ClientRegRequest.new(
        :security_server => security_server,
        :sec_serv_user => server_user,
        :origin => Request::SECURITY_SERVER)
      req.register()

      if auto_approve_and_request_verified_and_owner_exists
        client_reg_request = ClientRegRequest.new(
          :security_server => security_server,
          :sec_serv_user => server_user,
          :origin => Request::CENTER)
        client_reg_request.register()
      end
    end

    if auto_approve_and_request_verified_and_owner_exists
      # If subsystem to be added does not exist on Central Server yet, it
      # must be created before the approval
      if SecurityServerClient.find_by_id(server_user).nil?
        Subsystem.create!(
              :xroad_member => server_user_member,
              :subsystem_code => req_type.getClient().getSubsystemCode())
        logger.info("New subsystem created: #{server_user}")
      end
      RequestWithProcessing.approve(client_reg_request.id)
    end

    req.id
  end

  def handle_client_deletion
    req_type = ManagementRequestParser.parseClientDeletionRequest(@request_soap)
    security_server = security_server_id(req_type.getServer())
    server_user = client_id(req_type.getClient())

    verify_xroad_instance(security_server)
    verify_xroad_instance(server_user)

    verify_owner(security_server)

    req = ClientDeletionRequest.new(
      :security_server => security_server,
      :sec_serv_user => server_user,
      :origin => Request::SECURITY_SERVER)
    req.register()
    req.id
  end

  def security_server_id(id_type)
    SecurityServerId.from_parts(id_type.getXRoadInstance(),
      id_type.getMemberClass(), id_type.getMemberCode(),
      id_type.getServerCode())
  end

  def client_id(id_type)
    ClientId.from_parts(id_type.getXRoadInstance(), id_type.getMemberClass(),
      id_type.getMemberCode(), id_type.getSubsystemCode())
  end

  def member_id(id_type)
    ClientId.from_parts(id_type.getXRoadInstance(), id_type.getMemberClass(),
      id_type.getMemberCode())
  end

  def verify_owner(security_server)
    sender = client_id(@request_soap.getClient())
    verify_xroad_instance(sender)

    if not security_server.matches_client_id(sender)
      raise I18n.t("request.server_id_not_match_owner",
        :security_server => security_server.to_s,
        :sec_serv_owner => sender.to_s)
    end
  end

  # xroad_id may be either ClientId or ServerId.
  def verify_xroad_instance(xroad_id)
    logger.debug("Instance verification: #{xroad_id}")

    unless @xroad_instance.eql?(xroad_id.xroad_instance)
      raise t("request.incorrect_instance")
    end
  end

  def auto_approve_auth_cert_reg_requests?
    Java::ee.ria.xroad.common.SystemProperties::getCenterAutoApproveAuthCertRegRequests
  end

  def auto_approve_client_reg_requests?
    Java::ee.ria.xroad.common.SystemProperties::getCenterAutoApproveClientRegRequests
  end
end