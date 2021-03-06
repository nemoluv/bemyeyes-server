require 'rubygems'
require 'sinatra'
require "sinatra/config_file"
require 'sinatra/namespace'
require 'newrelic_rpm'
require 'opentok'
require 'mongo_mapper'
require 'json'
require 'aescrypt'
require 'bcrypt'
require 'json-schema'
require 'rufus-scheduler'
require 'redis'
require 'logster'
require 'pry'
require 'sucker_punch'
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
require_relative 'helpers/route_methods'
require_relative 'app_helpers/app_setup'
require_relative 'app_helpers/logster_setup.rb'
require_relative 'app_helpers/setup_logger'
require_relative 'middleware/auth'
require_relative 'middleware/basic_auth'
require_relative 'middleware/logster_env'

I18n.config.enforce_available_locales=false
class App < Sinatra::Base
  register Sinatra::ConfigFile

  config_file 'config/config.yml'

  def self.setup_mongo
    db_config = settings.config['database']
    if db_config['is_production']
      MongoMapper.setup({
        'production' => {
          'database' => db_config['name'],
          'hosts' => db_config['hosts'],
          :username => db_config['username'],
          :password => db_config['password']
        }
      }, 'production', {:pool_size  => 40, :read => :primary})
      MongoMapper.database.authenticate(db_config['username'], db_config['password'])
    else
      MongoMapper.connection = Mongo::Connection.new(db_config['host'])
      MongoMapper.database = db_config['name']
      MongoMapper.connection[db_config['name']]
    end
  end

  def self.start_cron_jobs
    db_config = settings.config['database']
    db_name = db_config['name']
    cron_job = CronJobs.new(Helper.new, requests_helper, Rufus::Scheduler.new, WaitingRequests.new, HelperPointChecker.new, db_name)
    cron_job.start_jobs
  end

  setup_logger

  # Do any configurations
  configure do
    set :app_file, __FILE__
    set :config, YAML.load_file('config/config.yml') rescue nil || {}
    set :scheduler, Rufus::Scheduler.new
    Encoding.default_external = 'UTF-8'

    opentok_config = settings.config['opentok']
    OpenTokSDK = OpenTok::OpenTok.new opentok_config['api_key'], opentok_config['api_secret']

    use BME::Auth
    use BME::BasicAuth
    use BME::LogsterEnv

    use Logster::Middleware::Viewer
    use PryRescue::Rack if ENV["RACK_ENV"] == 'development'

    setup_mongo
    start_cron_jobs
    $redis = Redis.new
  end

  setup_event_bus
  ensure_indeces

  before  do
    env["rack.errors"] = error_log
    AmbientRequest.instance.request = request
  end

  # Protect anything but the root
  before /^(?!\/reset-password)\/.+$/ do
    return if request.path_info == '/stats/community'
    protected!
  end

  before /^(?!\/(reset-password))\/.+$/ do
    content_type 'application/json'
  end

  # Root route
  get '/?' do
    redirect settings.config['redirect_root']
  end

  # Handle errors
  error do
    content_type :json
    status 500

    e = env["sinatra.error"]
    TheLogger.log.error(e.message)
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
