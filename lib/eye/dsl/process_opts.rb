class Eye::Dsl::ProcessOpts < Eye::Dsl::Opts

  def monitor_children(&block)
    opts = Eye::Dsl::ChildProcessOpts.new
    opts.instance_eval(&block) if block
    @config[:monitor_children] ||= {}
    Eye::Utils.deep_merge!(@config[:monitor_children], opts.config)
  end

  alias_method :xmonitor_children, :nop

  def application
    parent.try(:parent)
  end
  alias_method :app, :application
  alias_method :group, :parent

  def depend_on(names, opts = {})
    names = Array(names).map(&:to_s)
    trigger("wait_dependency_#{unique_num}", { names: names }.merge(opts))
    nm = @config[:name]
    names.each do |name|
      parent.process(name) do
        trigger("check_dependency_#{unique_num}", names: [nm])
      end
    end

    skip_group_action(:restart, [:up, :down, :starting, :stopping, :restarting])
  end

private

  def unique_num
    self.class.unique_num ||= 0
    self.class.unique_num += 1
  end

  class << self

    attr_accessor :unique_num

  end

end
