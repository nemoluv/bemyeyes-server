require 'rubygems'
require 'event_bus'
require 'sinatra'
require "sinatra/config_file"
require 'sinatra/namespace'
require 'newrelic_rpm'
require 'opentok'
require 'mongo_mapper'
require 'json'
require 'urbanairship'
require 'aescrypt'
require 'bcrypt'
require 'json-schema'
require 'rufus-scheduler'
require_relative 'helpers/requests_helper'
require_relative 'models/init'
require_relative 'routes/init'
require_relative 'event_handlers/init'
require_relative 'helpers/error_codes'
require_relative 'helpers/api_error'
require_relative 'helpers/cron_jobs'
require_relative 'helpers/thelogger_module'
require_relative 'helpers/waiting_requests'
require_relative 'helpers/date_helper'
require_relative 'helpers/helper_point_checker'
require_relative 'helpers/ambient_request'
I18n.config.enforce_available_locales=false
class App < Sinatra::Base
  register Sinatra::ConfigFile

  config_file 'config/config.yml'

  def self.requests_helper
    ua_config = settings.config['urbanairship']
    RequestsHelper.new ua_config, TheLogger
  end

  def self.setup_event_bus
    EventBus.subscribe(:request_stopped, MarkRequestStopped.new, :request_stopped)
    EventBus.subscribe(:request_stopped, AssignHelperPointsOnRequestStopped.new, :request_stopped)
    EventBus.subscribe(:request_answered, MarkRequestAnswered.new, :request_answered)
    EventBus.subscribe(:request_answered, requests_helper, :request_answered)
    EventBus.subscribe(:request_cancelled, requests_helper, :request_answered)
    EventBus.subscribe(:request_cancelled, MarkHelperRequestCancelled.new, :helper_request_cancelled)
    EventBus.subscribe(:request_cancelled, MarkRequestNotAnsweredAnyway.new, :request_cancelled)
    EventBus.subscribe(:helper_notified, MarkHelperNotified.new, :helper_notified)
    EventBus.subscribe(:helper_notified, AssignLastHelpRequest.new, :helper_notified)
    EventBus.subscribe(:user_saved, AssignLanguageToUser.new, :user_saved)
    send_reset_password_mail =SendResetPasswordMail.new settings
    EventBus.subscribe(:rest_password_token_created, send_reset_password_mail, :reset_password_token_created)
  end
  def self.ensure_indeces
    Helper.ensure_index(:last_help_request)
    HelperRequest.ensure_index(:request_id)
    Token.ensure_index(:expiry_time)
    AbuseReport.ensure_index(:blind_id)
    User.ensure_index([[:wake_up_in_seconds_since_midnight, 1], [:go_to_sleep_in_seconds_since_midnight, 1], [:role, 1]])
    Helper.ensure_index(:lanugages)
  end

  def self.access_logger
    @access_logger||= ::Logger.new(access_log, 'daily')
    @access_logger
  end

  def self.error_logger
    @error_logger ||= ::File.new(::File.join(::File.dirname(::File.expand_path(__FILE__)),'log','error.log'),"a+")
    @error_logger
  end

  def self.access_log
    @access_log ||= ::File.join(::File.dirname(::File.expand_path(__FILE__)),'log','access.log')
    @access_log
  end

  def error_log
    @error_log ||= ::File.new("log/error.log","a+")
    @error_log
  end

  def self.setup_logger
    #logging according to: http://spin.atomicobject.com/2013/11/12/production-logging-sinatra/
    ::Logger.class_eval { alias :write :'<<' }
    error_logger.sync = true
    TheLogger.log.level = Logger::DEBUG  # could be DEBUG, ERROR, FATAL, INFO, UNKNOWN, WARN
    TheLogger.log.formatter = proc { |severity, datetime, progname, msg| "[#{severity}] #{datetime.strftime('%Y-%m-%d %H:%M:%S')} : #{msg}\n" }
  end

  def self.setup_mongo
    db_config = settings.config['database']
    MongoMapper.connection = Mongo::Connection.new(db_config['host'])
    MongoMapper.database = db_config['name']
    if db_config.has_key? 'username'
      MongoMapper.connection[db_config['name']].authenticate(db_config['username'], db_config['password'])
    else
      MongoMapper.connection[db_config['name']]
    end
  end

  def self.start_cron_jobs
    cron_job = CronJobs.new(Helper.new, requests_helper, Rufus::Scheduler.new, WaitingRequests.new, HelperPointChecker.new)
    cron_job.start_jobs
  end

  setup_logger

  # Do any configurations
  configure do
    set :environment, :development
    set :dump_errors, true
    set :raise_errors, true
    set :show_exceptions, true
    enable :logging
    set :app_file, __FILE__
    set :config, YAML.load_file('config/config.yml') rescue nil || {}
    set :scheduler, Rufus::Scheduler.new
    Encoding.default_external = 'UTF-8'

    use ::Rack::CommonLogger, access_logger

    opentok_config = settings.config['opentok']
    OpenTokSDK = OpenTok::OpenTok.new opentok_config['api_key'], opentok_config['api_secret']

    setup_mongo
    start_cron_jobs
  end

  setup_event_bus
  ensure_indeces

  before  do
    env["rack.errors"] = error_log
    AmbientRequest.instance.request = request
  end

  # Protect anything but the root
  before /^(?!\/reset-password)\/.+$/ do
    protected!
  end

  before /^(?!\/((reset-password)|(log)))\/.+$/ do
    content_type 'application/json'
  end

  # Root route
  get '/?' do
    redirect settings.config['redirect_root']
  end

  get '/log/' do
    log_file = params[:file] || "app"
    log_file = "log/#{log_file}.log"

    if !File.exists? log_file
      log_file = "log/app.log"
    end
    File.read(log_file).gsub(/^/, '<br/>').gsub("[INFO]", "<span style='color:green'>[INFO]</span>").gsub("[ERROR]", "<span style='color:red'>[ERROR]</span>")
  end
  # Handle errors
  error do
    content_type :json
    status 500

    e = env["sinatra.error"]
    TheLogger.log.error(e)
    return { "result" => "error", "message" => e.message }.to_json
  end

  # Check if ww are authorized
  def authorized?
    auth_config = settings.config['authentication']
    @auth ||=  Rack::Auth::Basic::Request.new(request.env)
    @auth.provided? and @auth.basic? and @auth.credentials and @auth.credentials == [auth_config['username'], auth_config['password']]
  end

  def protected!
    return if authorized?
    content_type :json
    headers['WWW-Authenticate'] = 'Basic realm="Restricted Area"'
    halt 401, create_error_hash(ERROR_NOT_AUTHORIZED, "Not authorized.").to_json
  end

  # 404 not found
  not_found do
    content_type :json
    give_error(404, ERROR_RESOURCE_NOT_FOUND, "Resource not found.").to_json
  end
end
