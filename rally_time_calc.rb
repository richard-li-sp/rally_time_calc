require 'rally_api'
require 'rest-client'
require 'json'
require 'date'
require 'yaml'
require 'logger'

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
    request['start'] = page * pagesize
    response = rest.post(request.to_json, content_type: 'text/javascript')
    output = JSON.parse(response)

    result_count = output['TotalResultCount']

    results = output['Results']

    results.each do |item|
      begin
        obj = rally.read(object_type, item['ObjectID'])

        puts "-#{item['FormattedID']}:"

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
        else
          rally.update(object_type, item['ObjectID'], update) if do_fill
          puts "update: #{update}"
        end

      rescue Exception => e
        puts "Exception: #{e.backtrace}"
      end
    end

    page += 1
    sleep 1
  end until page * pagesize > result_count
rescue Exception => e
  puts "Exception, backtrace: #{e.backtrace.to_json}"
  raise e
end

conf = YAML.load_file('rally_time_calc.yml')

raise "No workspaces specified" unless conf['workspaces']
raise "Workspace needs to be an array" unless conf['workspaces'].is_a?(Hash)

conf['workspaces'].each do |name, info|
  raise "No workspace id found for #{name}" unless info['id']
  types = info['types']
  types = ['HierarchicalRequirement'] unless types

  lookback_url =
    "https://rally1.rallydev.com/analytics/v2.0/service/rally/workspace/" \
    "#{info['id']}/artifact/snapshot/query.js"

  types.each do |type|
    fill_clq(lookback_url, type, name,  info, true)
  end
end
