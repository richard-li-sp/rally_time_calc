#!/usr/bin/env ruby

require 'rally_api'
require 'rest-client'
require 'json'
require 'date'
require 'yaml'
require 'logger'

class CLQFill
  def initialize(wname, wid, user, pass, options, backtrack = 2)
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
    @update_all = (backtrack == 0 ? true : false)

    @backtrack = backtrack.to_i
    @backtrack = 2 if @backtrack.nil? || @backtrack <= 0

    @cycle_time = (options['fields']['cycle_time'] || 'c_CycleTime')
    @lead_time = (options['fields']['lead_time'] || 'c_LeadTime')
    @queue_time = (options['fields']['queue_time'] || 'c_QueueTime')
    @now = Time.now
    @today = @now.to_date
    @zero = Time.new(0)
    @zero_date = @zero.to_date
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

    (Date.parse(defined_output['Results'][0]['_ValidFrom']) rescue nil)
  end

  def get_designed_date(object_id)
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

  def calculate_cycle_time(id, accepted, in_progress_date, accepted_date)
    pagesize = 20
    state_scan = {
      'find' => {
        'ObjectID' => id
      },
      "sort" => { "_ValidFrom" => 1 },
      "fields" => [
        "ScheduleState",
        "_ValidFrom"
      ],
      "hydrate" => [
        "ScheduleState",
        "_ValidFrom"
      ],
      "pagesize" => pagesize
    }
    page = 0
    state_toggles = []
    current_state = false
    begin
      state_scan['start'] = page * pagesize

      states = JSON.parse(
        @lookback.post(state_scan.to_json, content_type: 'text/javascript')
      )
      result_count = states['TotalResultCount']
      results = states['Results']

      results.each do |item|
        if current_state && item['ScheduleState'] != 'In-Progress'
          state_toggles << item['_ValidFrom']
          current_state = false
        elsif !current_state && item['ScheduleState'] == 'In-Progress'
          state_toggles << item['_ValidFrom']
          current_state = true
        end
      end
      page += 1
      sleep 1
    end until page * pagesize > result_count

    puts "toggle: #{state_toggles}"

    if state_toggles.empty?
      cycle_time = 0

      return cycle_time if !accepted

      cycle_time = (accepted_date - in_progress_date).to_i if
        in_progress_date && accepted_date
      cycle_time = 1 if cycle_time < 1

      return cycle_time # minimum cycle 1 if it's accepted
    end

    current_state = true
    accumulation = 0
    previous_time = state_toggles.shift
    state_toggles.each do |state_time|
      if current_state
        accumulation += Time.parse(state_time) - Time.parse(previous_time)
      end
      previous_time = state_time
      current_state = !current_state
    end

    if !accepted && current_state
      accumulation += @now - Time.parse(previous_time)
    end

    ((@zero + accumulation).to_date - @zero_date).to_i
  end

  def fill(object_type)
    if @update_all
      puts "Refreshing ALL objects..."
    else
      puts "Update only, ongoing issues and accepted within last " \
           "#{@backtrack} days"
    end

    query = RallyAPI::RallyQuery.new()
    query.type = object_type
    query.query_string =
      '((AcceptedDate >= ' \
      "\"#{(DateTime.parse(Time.now.utc.to_s) - @backtrack).strftime('%FT%TZ')}\") OR " \
      "(AcceptedDate = null))" unless @update_all
    puts "Query: #{query.query_string}"
    objects = @rally.find(query)

    total_count = objects.count
    object_count = 0

    objects.each do |obj|
      obj.read
      puts "#{obj['FormattedID']}:"

      object_count += 1
      puts "#{object_count} of #{total_count}" if object_count % 10 == 0
      STDOUT.flush

      create_date = (Date.parse(obj['CreationDate']) rescue nil)
      accepted_date = (Date.parse(obj['AcceptedDate']) rescue nil)
      in_progress_date = (Date.parse(obj['InProgressDate']) rescue nil)
      defined_date = get_defined_date(obj['ObjectID'])
      designed_date = get_designed_date(obj['ObjectID'])

      if obj['ScheduleState'] != 'Accepted'
        cycle_time = calculate_cycle_time(obj['ObjectID'], false,
                                          in_progress_date,
                                          accepted_date
                                         )
        lead_time = (@today - create_date).to_i
        queue_time = (defined_date ? (@today - defined_date).to_i : 0)
      else
        cycle_time = calculate_cycle_time(obj['ObjectID'], true,
                                          in_progress_date,
                                          accepted_date
                                         )
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
        if @dryrun
          print "(Dryrun no update) "
        else
          @rally.update(object_type, obj['ObjectID'], update)
        end
        puts "update: #{update}"
        STDOUT.flush
      end
    end
  end

end

puts "Rally Time Calculator started: #{DateTime.now.to_s}"

conf = YAML.load_file('rally_time_calc.yml')

if ARGV.size > 0
  bt = ARGV[0].to_i
end

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

  clq = CLQFill.new(name, info['id'], info['user'], info['pass'], options, bt)

  types.each do |type|
    clq.fill(type)
    # fill_clq(lookback_url, type, name,  info, true)
  end
end

puts "Rally Time Calculator completed: #{DateTime.now.to_s}"
