# Modified from https://github.com/google/google-api-ruby-client-samples/blob/1480725b07e7048bc5dc7048606a016c5a8378a7/service_account/analytics.rb
# Inspired by https://gist.github.com/3166610
require 'active_record'
require 'active_support/time'
require 'date'
require 'google/api_client'
require 'sqlite3'
require 'yaml'

API_VERSION = 'v3'
CACHED_API_FILE = "#{ENV["TMPDIR"] || "/tmp"}/.ga-analytics-#{API_VERSION}.cache"

## Read Latcraft global configuration
global_config = YAML.load_file('/etc/latcraft.yml')
## Extract GA stats specific configuration
global_opts = global_config['google_analytics'] || {}

class GaQueryClient

 def initialize(opts)
    application_name = opts['application_name']
    application_version = opts['application_version']
    service_account_email = opts['service_account_email']  # Email of service account
    key_file = opts['key_file']                            # File containing your private key
    key_secret = opts['key_secret']                        # Password to unlock private key
    @profileID = opts['profile_id'].to_s                   # Analytics profile ID.

    @client = Google::APIClient.new(
      :application_name => application_name,
      :client_id => service_account_email,
      :application_version => application_version)

    ## Load our credentials for the service account
    key = Google::APIClient::KeyUtils.load_from_pkcs12(key_file, key_secret)

    @client.authorization = Signet::OAuth2::Client.new(
      :token_credential_uri => 'https://accounts.google.com/o/oauth2/token',
      :audience => 'https://accounts.google.com/o/oauth2/token',
      :scope => 'https://www.googleapis.com/auth/analytics.readonly',
      :issuer => service_account_email,
      :signing_key => key)

    @client.retries = 5
    ## Request a token for our service account
    @client.authorization.fetch_access_token!

    @analytics = nil
    ## Load cached discovered API, if it exists. This prevents retrieving the
    ## discovery document on every run, saving a round-trip to the discovery service.
    if File.exists? CACHED_API_FILE
      File.open(CACHED_API_FILE) do |file|
        @analytics = Marshal.load(file)
      end
    else
      @analytics = @client.discovered_api('analytics', API_VERSION)
      File.open(CACHED_API_FILE, 'w') do |file|
        Marshal.dump(@analytics, file)
      end
    end
  end

 ## Query Parameters Summary https://developers.google.com/analytics/devguides/reporting/core/v3/reference#q_summary
 ## Funcation to query google for a set of analytics attributes
 def query_iterate!(start_date, end_date, metrics, dimensions, sort, &block)
   request = {
     :api_method => @analytics.data.ga.get,
     :parameters => {
       'ids' => "ga:" + @profileID,
       'start-date' => start_date.strftime("%Y-%m-%d"),
       'end-date' => end_date.strftime("%Y-%m-%d"),
       'metrics' => metrics,
       'dimensions' => dimensions,
       'sort' => sort,
     },
   }

   page = 0

   loop do
     result = @client.execute!(request)
     page += 1

     # For some weird reason Google API do not throw exceptions in this endpoint
     # And don't have `.success` kind of status checks
     #
     # Instead we need to check result for HTTP status codes ourselves (manually).
     # In our case we've decided to throw exception.
     if result.status == 200 then
       # Everything is OK
     else
       # Error, like HTTP 403, permission denied
       # Rewrap in Google ClientError
       raise Google::APIClient::ClientError.new "GA error #{result.data.error['code']}: #{result.data.error['message']}"
     end

     block.call(result.data)

     # GA api has broken pagination support.
     # Idiomatic Google API service should use next_page_token and next_page
     # HOWEVER, GA v3 does not handle that well (as expected)
     # Thus, in case of paging - we need to do manually by request parameters
     break unless result.data.next_link
     request[:parameters]['start-index'] = page * result.data.itemsPerPage + 1
     request[:parameters]['max-results'] = result.data.itemsPerPage
   end
 end

end

class GaSQLiteDB
  @@db_con = nil

  def initialize(global_opts)
    @@db_path = global_opts['ga_db_path'] || '/var/lib/sqlite/ga-metrics.db'
    if @@db_con.nil? then
      @@db_con = SQLite3::Database.new @@db_path
    end

    GaActiveModule::GaActiveRecord.establish_connection(
      :adapter => 'sqlite3',
      :database => @@db_path
    )
  end

  def execute(sql)
    @@db_con.execute(sql)
  end

  def generate_active_record(name)
    #TODO: Check for Memory leak

    klazz = Class.new(GaActiveModule::GaActiveRecord) do
      self.table_name = name
    end
    klazz.table_name = name
    klazz.reset_column_information
    klazz
  end

end

# Standalone module / base abstract class - to enable work via ActiveRecord
# Not via raw SQL
module GaActiveModule
  class GaActiveRecord < ActiveRecord::Base
    self.abstract_class = true

    self.table_name = "CHANGE ME IN RUNTIME"
  end
end

class GaSQLiteMetrics
  # Known / Supported metric data types
  @@types = {
    "STRING"  => "TEXT",
    "INTEGER" => "INTEGER",
    "PERCENT" => "NUMBER(3,2)",
    "TIME"    => "NUMBER(3,2)",
    "FLOAT"   => "REAL",
  }

  def initialize(db, name)
    @db = db
    @name = name
  end

  def create_table!(data)
    columns = ["ga_period TEXT"] + data.column_headers.map{|c| "#{_column(c.name)} #{@@types[c.dataType] || 'TEXT'}"}
    # We get back two kinds of data columns: DIMENSION and METRIC
    #   Dimension is usually filter criteria
    #   Metric actual data
    index_columns = ["ga_period"] + data.column_headers.select{|h| h.columnType == "DIMENSION"}.map{|c| _column(c.name)}

    sqls = [
      "CREATE TABLE IF NOT EXISTS #{@name}(#{columns.join(", ")});",
      "CREATE UNIQUE INDEX IF NOT EXISTS #{@name}_DIMENSION ON #{@name} (#{index_columns.join(", ")});",
    ]

    sqls.each { |sql| @db.execute(sql) }
  end

  def push_data!(period, data)
    _Q = active_record
    _Q.where(ga_period: period).delete_all

    data.rows.map {|row|
      q = _Q.new
      q.attributes = Hash[data.column_headers.map {|c| _column(c.name)}.zip(row)]
      q.ga_period = period
      q.save
    }
  end

  def active_record
    @db.generate_active_record(@name)
  end

  def _column(name)
    name.gsub("ga:", "")
  end

end

db_con = GaSQLiteDB.new(global_opts)
client = GaQueryClient.new(global_opts)
attributes_yaml = lambda do |name|
  ## Dimensions and Metrics Reference: https://developers.google.com/analytics/devguides/reporting/core/dimsmets
  ## A single dimension data request to be retrieved from the API is limited to a maximum of 7 dimensions
  ## A single metrics data request to be retrieved from the API is limited to a maximum of 10 metrics
  ga_attributes_yml = global_opts["ga_attributes_#{name}_yml"]

  ## Set of dimensions and metrics to query in a file and iterate
  YAML.load_file(ga_attributes_yml)
end

class GaFetchSchedule
  def initialize(db_con, client, attributes_yaml)
    @db_con = db_con
    @client = client
    @attributes_yaml = attributes_yaml
  end
end

class GaFetchMonthly < GaFetchSchedule
  def call(job)
    begin
      attributes = @attributes_yaml.call("monthly")
      # will query for previous month
      month_start = DateTime.now.prev_month.at_beginning_of_month
      month_end = DateTime.now.prev_month.at_end_of_month

      attributes.each_key { |name|
        metrics, dimensions, sort = attributes[name]['metric'], attributes[name]['dimension'], attributes[name]['sort']
        @client.query_iterate!(month_start, month_end, metrics, dimensions, sort) { |gadata|
          sql_data = GaSQLiteMetrics.new(@db_con, name)
          sql_data.create_table!    gadata
          sql_data.push_data!       "month_#{month_start.strftime('%Y_%m')}", gadata
        }
      }
    rescue => e
      puts "\e[33mFor the GA check /etc/latcraft.yml for the credentials and metrics YML.\n\tError: #{e.message}\e[0m"
    end
  end
end

class GaFetchDaily < GaFetchSchedule
  def call(job)
    begin
      attributes = @attributes_yaml.call("daily")
      # will query for one single date, yesterday
      prev_day = DateTime.now.yesterday

      attributes.each_key { |name|
        metrics, dimensions, sort = attributes[name]['metric'], attributes[name]['dimension'], attributes[name]['sort']
        @client.query_iterate!(prev_day, prev_day, metrics, dimensions, sort) { |gadata|
          sql_data = GaSQLiteMetrics.new(@db_con, name)
          sql_data.create_table!    gadata
          sql_data.push_data!       "daily_#{prev_day.strftime('%Y_%m_%d')}", gadata
        }
      }
    rescue => e
      puts "\e[33mFor the GA check /etc/latcraft.yml for the credentials and metrics YML.\n\tError: #{e.message}\e[0m"
    end
  end
end

class GaFetchToday < GaFetchSchedule
  def call(job)
    begin
      ## FIXME? No need to store, send to widget instead immediately?
      attributes = @attributes_yaml.call("today")
      # will query for one single date, today
      today = DateTime.now

      attributes.each_key { |name|
        metrics, dimensions, sort = attributes[name]['metric'], attributes[name]['dimension'], attributes[name]['sort']
        @client.query_iterate!(today, today, metrics, dimensions, sort) { |gadata|
          sql_data = GaSQLiteMetrics.new(@db_con, name)
          sql_data.create_table!    gadata
          sql_data.push_data!       "today", gadata
        }
      }
    rescue => e
      puts e.backtrace
      puts "\e[33mFor the GA check /etc/latcraft.yml for the credentials and metrics YML.\n\tError: #{e.message}\e[0m"
    end
  end
end

# Aggregate previous day GA stats, on first day, each month, five minutes after midnight
SCHEDULER.cron '5 0 1 * *', GaFetchMonthly.new(db_con, client, attributes_yaml)
SCHEDULER.in "10m", GaFetchMonthly.new(db_con, client, attributes_yaml)

# Aggregate previous day GA stats, every day, five minutes after midnight
SCHEDULER.cron '5 0 * * *', GaFetchDaily.new(db_con, client, attributes_yaml)
SCHEDULER.in "15m", GaFetchDaily.new(db_con, client, attributes_yaml)

# Aggregate today's GA stats
SCHEDULER.every '30m', GaFetchToday.new(db_con, client, attributes_yaml)
SCHEDULER.at Time.now, GaFetchToday.new(db_con, client, attributes_yaml)

class GaWidget
  def initialize(db_con)
    @db_con = db_con
  end
end

class GaNewUsersPrevMonth < GaWidget
  def call(job)
    period_start = DateTime.now.prev_month.at_beginning_of_month
    new_users = @db_con.execute("select round(1.0 * sum(newUsers) / sum(users) * 100, 1)
                                from VisitsCount
                                where ga_period = 'month_#{period_start.strftime('%Y_%m')}'");
    send_event('ga_new_users_prev_month', { value: new_users })
  end
end

class GaUsersToday < GaWidget
  @previous = 0
  def call(job)
    sessions_today = @db_con.execute("select sum(sessions) from VisitCountvisitorType where ga_period = 'today'");
    send_event('ga_today_sessions', { current: sessions_today, last: @previous })
    @previous = sessions_today
  end
end

class GaUsersGraph < GaWidget
  def call(job)
    now = DateTime.now
    data = @db_con.execute("select cast(hour as integer) ihour, sessions
                           from HourOfDayMonth 
                           where ga_period='today' and ihour='#{now.hour}'");
    points = data.map {|row| { :x => now.to_i, :y => row[1] } }

    send_event('ga_sessions_today_graph', { points: points })
  end
end

#
SCHEDULER.every '5m', GaNewUsersPrevMonth.new(db_con)
SCHEDULER.at Time.now, GaNewUsersPrevMonth.new(db_con)

ga_users_todays_widget = GaUsersToday.new(db_con)
SCHEDULER.every '5m', ga_users_todays_widget
SCHEDULER.at Time.now, ga_users_todays_widget

SCHEDULER.every '5m', GaUsersGraph.new(db_con)
SCHEDULER.at Time.now, GaUsersGraph.new(db_con)
