#!/usr/bin/env ruby

require 'rally_api'
require 'rest-client'
require 'json'
require 'date'
require 'yaml'
require 'logger'

class CLQFill
  def initialize(wname, wid, user, pass, options)
    @lookback =
      RestClient::Resource.new(
        "https://rally1.rallydev.com/analytics/v2.0/service/rally/workspace/" \
        "#{wid}/artifact/snapshot/query.js",
        user,
        pass
      )
    @rally = RallyAPI::RallyRestJson.new(
      base_url: 'https://rally1.rallydev.com/slm',
      username: user,
      password: pass,
      version: 'v2.0',
      workspace: wname
    )
    @dryrun = options['dryrun'] ? true : false
    @update_all = options['update_all'] ? true : false

    @cycle_time = (options['fields']['cycle_time'] || 'c_CycleTime')
    @lead_time = (options['fields']['lead_time'] || 'c_LeadTime')
    @queue_time = (options['fields']['queue_time'] || 'c_QueueTime')
    @today = Date.today
    @enable = (options['enable'] || [])
  end

  def get_defined_date(object_id)
    defined_request = {
      "find" => {
        'ObjectID' => object_id,
        "ScheduleState" => "Defined",
      },
      "sort" => {
        "_ValidFrom" => 1
      },
      "fields" => [
        "_ValidFrom",
      ],
      "pagesize" => 1,
    }

    defined_output = JSON.parse(
      @lookback.post(defined_request.to_json, content_type: 'text/javascript')
    )

    (Date.parse(defined_output['Results'][0]['_ValidateFrom']) rescue nil)
  end

  def get_design_date(object_id)
    designed_request = {
      'find' => {
        'ObjectID' => object_id,
        'PlanEstimate' => {'$ne' => 0}
      },
      'sort' => {
        '_ValidFrom' => 1
      },
      'fields' => [
        '_ValidFrom'
      ],
      'pagesize' => 1
    }
    designed_output = JSON.parse(
      @lookback.post(designed_request.to_json, content_type: 'text/javascript')
    )
    (Date.parse(designed_output['Results'][0]['_ValidateFrom']) rescue nil)
  end

  def fill(object_type)
    pagesize = 20
    query = RallyAPI::RallyQuery.new()
    query.type = object_type
    query.query_string =
      '((AcceptedDate >= ' \
      "#{(DateTime.parse(Time.now.utc.to_s) - 2).strftime('%FT%TZ')}) OR"
      "(AcceptedDate = null))" unless @update_all
    objects = @rally.find(query)

    objects.each do |obj|
      obj.read
      puts "#{obj['FormattedID']}:"
      STDOUT.flush

      create_date = (Date.parse(obj['CreationDate']) rescue nil)
      accepted_date = (Date.parse(obj['AcceptedDate']) rescue nil)
      in_progress_date = (Date.parse(obj['InProgressDate']) rescue nil)
      defined_date = get_defined_date(obj['ObjectID'])
      designed_date = get_designed_date(obj['ObjectID'])

      if obj['ScheduleState'] != 'Accepted'
        cycle_time = if in_progress_date
                       (@today - in_progress_date).to_i
                     else
                       0
                     end
        lead_time = (designed_date ? (today - designed_date).to_i : 0)
        queue_time = (defined_date ? (today - defined_date).to_i : 0)
      else
        cycle_time = if in_progress_date
                       (accepted_date - in_progress_date).to_i
                     else
                       1
                     end
        lead_time = if designed_date
                      (accepted_date - designed_date).to_i
                    else
                      (accepted_date - created_date).to_i
                    end
        queue_time = if defined_date
                       if in_progress_date
                         (in_progress_date - defined_date).to_i
                       else
                         (accepted_date - defined_date).to_i
                       end
                     else
                       0
                     end
      end

      puts "c:#{cycle_time}, l:#{lead_time}, q:#{queue_time}"
      STDOUT.flush

      update = {}

      if @enable.include?('cycle_time')
        update[@cycle_time] = cycle_time unless
          cycle_time == obj[@cycle_time]
      end
      if @enable.include?('lead_time')
        update[@lead_time] = lead_time unless
          lead_time == obj[@lead_time]
      end
      if @enable.include?('queue_time')
        update[@queue_time] = queue_time unless
          queue_time == obj[@queue_time]
      end

      if update.empty?
        puts "No update"
        STDOUT.flush
      else
        @rally.update(object_type, obj['ObjectID'], update) unless @dryrun
        puts "update: #{update}"
        STDOUT.flush
      end
    end
  end

end

def fill_clq(lookback_url, object_type, name, info, do_fill = false)

  user = info['user']
  pass = info['pass']

  pagesize = 20

  rest = RestClient::Resource.new(lookback_url, user, pass)

  rally_api_config = {
    base_url: 'https://rally1.rallydev.com/slm',
    username: user,
    password: pass,
    version: 'v2.0',
    workspace: name,
  }

  rally = RallyAPI::RallyRestJson.new(rally_api_config)

  request = {
    "find" => {
      "_TypeHierarchy" => object_type,
      "__At" => 'current',
    },
    "sort" => {
      "_ValidTo" => -1
    },
    "fields" => [
      "ObjectID",
      "FormattedID",
      "ScheduleState",
      "CreationDate",
      "AcceptedDate",
      "InProgressDate",
      "_ValidFrom",
      "_ValidTo"
    ],
    "hydrate" => [
      "FormattedID",
      "ScheduleState"
    ],
    "pagesize" => pagesize,
  }


  request['find']['Project'] = info['filters']['project'] if
    info['filters'] && info['filters']['project']

  defined_request = {
    "find" => {
      "_TypeHierarchy" => object_type,
      "ScheduleState" => "Defined",
    },
    "sort" => {
      "_ValidFrom" => 1
    },
    "fields" => [
      "_ValidFrom",
    ],
    "pagesize" => 1,
  }



  page = 0

  begin
    puts "---Page #{page}---"
    STDOUT.flush
    request['start'] = page * pagesize
    response = rest.post(request.to_json, content_type: 'text/javascript')
    output = JSON.parse(response)

    result_count = output['TotalResultCount']

    results = output['Results']

    results.each do |item|
      begin
        obj = rally.read(object_type, item['ObjectID'])

        puts "-#{item['FormattedID']}:"
        STDOUT.flush

        create_date = (Date.parse(item['CreationDate']) rescue nil)
        accepted_date = (Date.parse(item['AcceptedDate']) rescue nil)
        in_progress_date = (Date.parse(item['InProgressDate']) rescue nil)

  #---get defined date
        defined_request['find']['ObjectID'] = item['ObjectID']

        defined_output =
          JSON.parse(
            rest.post(defined_request.to_json, content_type: 'text/javascript')
        )

        defined_date =
          (Date.parse(defined_output['Results'][0]['_ValidFrom']) rescue nil)

        update = {}

        if item['ScheduleState'] != 'Accepted'
          today = Date.today
          # time for object not accepted yet
          cycle_time = if in_progress_date
                         (today - in_progress_date).to_i
                       else
                         0 # if not in progress, then 0 cycle time
                       end
          lead_time = (today - create_date).to_i
          queue_time = (defined_date ? (today - defined_date).to_i : 0)
        else
          # time for accepted opbjects
          cycle_time = if in_progress_date
                         (accepted_date - in_progress_date).to_i
                       else
                         1 # minimum cycle time is 1
                       end
          lead_time = (accepted_date - create_date).to_i
          queue_time = if defined_date
                         if in_progress_date
                           (in_progress_date - defined_date).to_i
                         else
                           (accepted_date - defined_date).to_i
                         end
                       else
                         0
                       end
        end

        puts "c:#{cycle_time}, l:#{lead_time}, q:#{queue_time}"
        STDOUT.flush

        if info['enable']
          if info['enable'].include?('cycle_time')
            cycle_time_name = (info['fields']['cycle_time'] || 'c_CycleTime')
            update[cycle_time_name] = cycle_time unless
              cycle_time == obj[cycle_time_name]
          end
          if info['enable'].include?('lead_time')
            lead_time_name = (info['fields']['lead_time'] || 'c_LeadTime')
            update[lead_time_name] = lead_time unless
              lead_time == obj[lead_time_name]
          end
          if info['enable'].include?('queue_time')
            queue_time_name = (info['fields']['queue_time'] || 'c_QueueTime')
            update[queue_time_name] = queue_time unless
              queue_time == obj[queue_time_name]
          end
        end

        if update.empty?
          puts "No update"
          STDOUT.flush
        else
          rally.update(object_type, item['ObjectID'], update) if do_fill
          puts "update: #{update}"
          STDOUT.flush
        end

      rescue Exception => e
        puts "Exception: #{e.backtrace}"
        STDOUT.flush
      end
    end

    page += 1
    sleep 1
  end until page * pagesize > result_count
rescue Exception => e
  puts "Exception, backtrace: #{e.backtrace.to_json}"
  STDOUT.flush
  raise e
end

puts "Rally Time Calculator started: #{DateTime.now.to_s}"

conf = YAML.load_file('rally_time_calc.yml')

raise "No workspaces specified" unless conf['workspaces']
raise "Workspace needs to be an array" unless conf['workspaces'].is_a?(Hash)

conf['workspaces'].each do |name, info|
  raise "No workspace id found for #{name}" unless info['id']
  types = info['objects']
  types = ['HierarchicalRequirement'] unless types

  lookback_url =
    "https://rally1.rallydev.com/analytics/v2.0/service/rally/workspace/" \
    "#{info['id']}/artifact/snapshot/query.js"

  pick = %{dryrun update_all fields enable}

  options = info.select {|name, _| pick.include?(name)}

  clq = CLQFill.new(name, info['id'], info['user'], info['pass'], options)

  types.each do |type|
    fill_clq(lookback_url, type, name,  info, true)
  end
end

puts "Rally Time Calculator completed: #{DateTime.now.to_s}"
