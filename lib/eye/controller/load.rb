module Eye::Controller::Load

  def check(filename)
    { filename => catch_load_error(filename) { parse_config(filename).to_h } }
  end

  def explain(filename)
    { filename => catch_load_error(filename) { parse_config(filename).to_h } }
  end

  def load(*args)
    args.extract_options!
    obj_strs = args.flatten
    info "=> loading: #{obj_strs}"

    res = {}

    globbing(*obj_strs).each do |filename|
      res[filename] = catch_load_error(filename) do
        cfg = parse_config(filename)
        load_config(filename, cfg)
        nil
      end
    end

    set_proc_line

    info "<= loading: #{obj_strs}"

    res
  end

private

  # regexp for clean backtrace to show for user
  BT_REGX = %r[/lib/eye/|lib/celluloid|internal:prelude|logger.rb:|active_support/core_ext|shellwords.rb|kernel/bootstrap]

  def catch_load_error(filename = nil, &_block)
    { error: false, config: yield }

  rescue Eye::Dsl::Error, Exception, NoMethodError => ex
    raise if ex.class.to_s.include?('RR') # skip RR exceptions

    error "loading: config error <#{filename}>: #{ex.message}"

    # filter backtrace for user output
    bt = (ex.backtrace || [])
    bt = bt.reject { |line| line.to_s =~ BT_REGX } unless ENV['EYE_FULL_BACKTRACE']
    error bt.join("\n")

    res = { error: true, message: ex.message }
    res[:backtrace] = bt if bt.present?
    res
  end

  def globbing(*obj_strs)
    res = []
    return res if obj_strs.empty?

    obj_strs.each do |filename|
      next unless filename

      mask = File.directory?(filename) ? File.join(filename, '{*.eye}') : filename
      debug { "loading: globbing mask #{mask}" }

      sub = []
      Dir[mask].each do |config_path|
        sub << config_path
      end
      sub = [mask] if sub.empty?

      res += sub
    end

    res
  end

  # return: result, config
  def parse_config(filename)
    debug { "parsing: #{filename}" }
    Eye::Dsl.parse(nil, filename)
  end

  # !!! exclusive operation
  def load_config(filename, config)
    info "loading: #{filename}"
    new_cfg = @current_config.merge(config)
    new_cfg.validate!(config.application_names)

    load_options(new_cfg.settings)
    create_objects(new_cfg.applications, config.application_names)
    @current_config = new_cfg
  end

  # load global config options
  def load_options(opts)
    return if opts.blank?

    opts.each do |key, value|
      method = "set_opt_#{key}"
      send(method, value) if value && respond_to?(method)
    end
  end

  # create objects as diff, from configs
  def create_objects(apps_config, changed_apps = [])
    debug { 'creating objects' }

    apps_config.each do |app_name, app_cfg|
      update_or_create_application(app_name, app_cfg.clone) if changed_apps.include?(app_name)
    end

    # sorting applications
    @applications.sort_by!(&:name)
  end

  def update_or_create_application(app_name, app_config)
    @old_groups = {}
    @old_processes = {}

    app = @applications.detect { |c| c.name == app_name }

    if app
      app.groups.each do |group|
        @old_groups[group.name] = group
        group.processes.each do |proc|
          @old_processes[group.name + ':' + proc.name] = proc
        end
      end

      @applications.delete(app)

      debug { "updating app: #{app_name}" }
    else
      debug { "creating app: #{app_name}" }
    end

    app = Eye::Application.new(app_name, app_config)
    @applications << app
    @added_groups = []
    @added_processes = []

    new_groups = app_config.delete(:groups) || {}
    new_groups.each do |group_name, group_cfg|
      group = update_or_create_group(group_name, group_cfg.clone)
      app.add_group(group)
      group.resort_processes
    end

    # now, need to clear @old_groups, and @old_processes
    @old_groups.each do |_, group|
      group.clear
      group.send_call(command: :delete, reason: 'load by user')
    end
    @old_processes.each do |_, process|
      process.send_call(command: :delete, reason: 'load by user') if process.alive?
    end

    # schedule monitoring for new groups, processes
    added_fully_groups = []
    @added_groups.each do |group|
      if !group.processes.empty? && (group.processes.pure - @added_processes).empty?
        added_fully_groups << group
        @added_processes -= group.processes.pure
      end
    end

    added_fully_groups.each { |group| group.send_call command: :monitor, reason: 'load by user' }
    @added_processes.each { |process| process.send_call command: :monitor, reason: 'load by user' }

    # remove links to prevent memory leaks
    @old_groups = nil
    @old_processes = nil
    @added_groups = nil
    @added_processes = nil

    app.resort_groups

    app
  end

  def update_or_create_group(group_name, group_config)
    group = if @old_groups[group_name]
      debug { "updating group: #{group_name}" }
      group = @old_groups.delete(group_name)
      group.send_call command: :update_config, args: [group_config], reason: 'load by user'
      group.clear
      group
    else
      debug { "creating group: #{group_name}" }
      gr = Eye::Group.new(group_name, group_config)
      @added_groups << gr
      gr
    end

    processes = group_config.delete(:processes) || {}
    processes.each do |process_name, process_cfg|
      process = update_or_create_process(process_name, process_cfg.clone)
      group.add_process(process)
    end

    group
  end

  def update_or_create_process(process_name, process_cfg)
    postfix = ':' + process_name
    name = process_cfg[:group] + postfix
    key = @old_processes[name] ? name : @old_processes.keys.detect { |n| n.end_with?(postfix) }

    if @old_processes[key]
      debug { "updating process: #{name}" }
      process = @old_processes.delete(key)
      process.send_call command: :update_config, args: [process_cfg], reason: 'load by user'
    else
      debug { "creating process: #{name}" }
      process = Eye::Process.new(process_cfg)
      @added_processes << process
    end

    process
  end

end
