require_relative '../helpers/requests_helper'
class App < Sinatra::Base
  register Sinatra::Namespace

  # Begin requests namespace
  namespace '/requests' do

    # Create new request
    post '/?' do
      begin
        body_params = JSON.parse(request.body.read)
        token_repr = body_params["token"]
        TheLogger.log.info("request post, token " + token_repr )
      rescue Exception => e
        give_error(400, ERROR_INVALID_BODY, "The body is not valid.").to_json
      end

      token = token_from_representation_with_validation(token_repr, true)
      user = token.user

      begin
        session = OpenTokSDK.create_session()
        session_id = session.session_id
        token = OpenTokSDK.generate_token session_id
      rescue Exception => e
        give_error(500, ERROR_REQUEST_SESSION_NOT_CREATED, "The session could not be created. " + e.message)
      end

      # Store request in database
      request = Request.create
      request.short_id_salt = settings.config["short_id_salt"]
      request.session_id = session_id
      request.token = token
      request.blind = user
      request.answered = false
      request.save!
      #TODO set all this in helper method since it's reused in the cronjob...
      #1. Find helpers
      helper = Helper.new
      helpers = helper.available(request, 10)
      #2. Find device tokens
      tokens = helpers.collect { |u| u.devices.collect { |d| d.device_token } }.flatten
      #3. Send notification
      requests_helper = RequestsHelper.new
      requests_helper.send_notifications request, tokens
      #4. Set notified helpers as contacted for this request.
      requests_helper.set_sent_helper helpers, request
    
      return request.to_json
    end

    # Get a request
    get '/:short_id' do
        TheLogger.log.info("get request, shortId:  " + params[:short_id] )
      return request_from_short_id(params[:short_id]).to_json
    end

    # Answer a request
    put '/:short_id/answer' do
      begin
        body_params = JSON.parse(request.body.read)
        token_repr = body_params["token"]

        TheLogger.log.info("answer request, token  " + token_repr )
      rescue Exception => e
        give_error(400, ERROR_INVALID_BODY, "The body is not valid.").to_json
      end

      token = token_from_representation_with_validation(token_repr, true)
      user = token.user
      request = request_from_short_id(params[:short_id])

      if request.answered?
        request.helper = user
        point = HelperPoint.answer_push_message
        request.helper.helper_points.push point
        request.helper.save
        give_error(400, ERROR_REQUEST_ALREADY_ANSWERED, "The request has already been answered.").to_json
      elsif request.stopped?
        give_error(400, ERROR_REQUEST_STOPPED, "The request has been stopped.").to_json
      else
        # Update request
        request.helper = user
        request.answered = true
        request.save!

        return request.to_json
      end
    end

    # A helper can cancel his own answer. This should only be done if the session has not already started.
    put '/:short_id/answer/cancel' do
      begin
        body_params = JSON.parse(request.body.read)
        token_repr = body_params["token"]
      rescue Exception => e
        give_error(400, ERROR_INVALID_BODY, "The body is not valid.").to_json
      end

      token = token_from_representation_with_validation(token_repr, true)
      user = token.user
      request = request_from_short_id(params[:short_id])

      if request.stopped?
        give_error(400, ERROR_EQUEST_STOPPED, "The request has been stopped.").to_json
      elsif request.helper._id != user._id
        give_error(400, ERROR_NOT_PERMITTED, "This action is not permitted for the user.").to_json
      end

      # Update request
      request.helper = nil
      request.answered = false
      request.save!

      return request.to_json
    end

    # The blind or a helper can disconnect from a started session thereby stopping the session.
    put '/:short_id/disconnect' do
      begin
        body_params = JSON.parse(request.body.read)
        token_repr = body_params["token"]
      rescue Exception => e
        give_error(400, ERROR_INVALID_BODY, "The body is not valid.").to_json
      end

      token = token_from_representation_with_validation(token_repr, true)
      user = token.user
      request = request_from_short_id(params[:short_id])

      if request.stopped?
        give_error(400, ERROR_EQUEST_STOPPED, "The request has been stopped.").to_json
      elsif request.blind._id != user._id && request.helper._id != user._id
        give_error(400, ERROR_NOT_PERMITTED, "This action is not permitted for the user.").to_json
      end

      # Update request
      request.stopped = true
      request.save!
      
      #update helper with points for call
      point = HelperPoint.finish_helping_request 
      request.helper.helper_points.push point
      request.helper.save
      
      return request.to_json
    end

    # Rate a request
    put '/:short_id/rate' do
      begin
        body_params = JSON.parse(request.body.read)
        rating = body_params["rating"]
        token_repr = body_params["token"]
      rescue Exception => e
        give_error(400, ERROR_INVALID_BODY, "The body is not valid.").to_json
      end

      token = token_from_representation_with_validation(token_repr, true)
      user = token.user
      request = request_from_short_id(params[:short_id])

      if request.answered?
        if user.role == "blind"
          request.blind_rating = rating
          request.save!
        elsif user.role == "helper"
          request.helper_rating = rating
          request.save!
        end
      else
        give_error(400, ERROR_REQUEST_NOT_ANSWERED, "The request has not been answered and can therefore not be rated.").to_json
      end
    end

  end # End namespace /request

  # Find a request from a short ID
  def request_from_short_id(short_id)
    request = Request.first(:short_id => short_id)
    if request.nil?
      give_error(400, ERROR_REQUEST_NOT_FOUND, "Request not found.").to_json
    end

    return request
  end

  # Find token by representation of the token
  def token_from_representation_with_validation(repr, validation)
    token = Token.first(:token => repr)
    if token.nil?
      give_error(400, ERROR_USER_TOKEN_NOT_FOUND, "Token not found.").to_json
    end

    if validation && !token.valid?
      give_error(400, ERROR_USER_TOKEN_EXPIRED, "Token has expired.").to_json
    end

    return token
  end

end
