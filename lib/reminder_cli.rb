# frozen_string_literal: true

require 'fileutils'
require 'json'
require 'optparse'
require 'open3'
require 'time'
require 'securerandom'
require 'date'

module ReminderCLI
  class Error < StandardError; end

  SOURCE_SCRIPT_PATH = File.expand_path(File.join(__dir__, '..', 'reminder'))
  SOURCE_LIB_PATH = File.expand_path(__FILE__)

  class << self
    attr_writer :app_dir, :launch_agents_dir, :script_path, :time_source, :id_generator
  end

  APP_TITLE = 'Reminder CLI'

  def self.app_dir
    @app_dir ||= File.join(Dir.home, '.reminder-cli')
  end

  def self.db_path
    File.join(app_dir, 'reminders.json')
  end

  def self.runtime_dir
    File.join(app_dir, 'runtime')
  end

  def self.runtime_lib_dir
    File.join(runtime_dir, 'lib')
  end

  def self.runtime_script_path
    File.join(runtime_dir, 'reminder')
  end

  def self.runtime_lib_path
    File.join(runtime_lib_dir, 'reminder_cli.rb')
  end

  def self.launch_agents_dir
    @launch_agents_dir ||= File.join(Dir.home, 'Library', 'LaunchAgents')
  end

  def self.script_path
    @script_path ||= runtime_script_path
  end

  def self.install_runtime_files
    script_already_installed = File.identical?(SOURCE_SCRIPT_PATH, runtime_script_path)
    lib_already_installed = File.identical?(SOURCE_LIB_PATH, runtime_lib_path)

    FileUtils.mkdir_p(runtime_lib_dir)
    FileUtils.cp(SOURCE_SCRIPT_PATH, runtime_script_path) unless script_already_installed
    FileUtils.cp(SOURCE_LIB_PATH, runtime_lib_path) unless lib_already_installed

    FileUtils.chmod(0o755, runtime_script_path)
  end

  def self.time_source
    @time_source ||= -> { Time.now }
  end

  def self.id_generator
    @id_generator ||= -> { SecureRandom.hex(4) }
  end

  def self.reset_configuration!
    @app_dir = nil
    @launch_agents_dir = nil
    @script_path = nil
    @time_source = nil
    @id_generator = nil
  end

  def self.ensure_dirs
    FileUtils.mkdir_p(app_dir)
    FileUtils.mkdir_p(launch_agents_dir)
    install_runtime_files if @script_path.nil?
    File.write(db_path, "[\n]\n") unless File.exist?(db_path)
  end

  def self.load_db
    ensure_dirs
    JSON.parse(File.read(db_path))
  rescue JSON::ParserError => e
    raise Error, "Banco de reminders corrompido em #{db_path}: #{e.message}"
  end

  def self.save_db(items)
    File.write(db_path, "#{JSON.pretty_generate(items)}\n")
  end

  def self.parse_datetime(value)
    formats = ['%Y-%m-%d %H:%M', '%Y-%m-%d %H:%M:%S', '%Y-%m-%dT%H:%M', '%Y-%m-%dT%H:%M:%S']
    formats.each do |format|
      return Time.strptime(value, format)
    rescue ArgumentError
      next
    end
    raise Error, "Formato de data invalido. Use 'YYYY-MM-DD HH:MM' ou 'YYYY-MM-DDTHH:MM'."
  end

  def self.parse_duration(value)
    raw = value.strip.downcase
    return raw.to_i * 60 if raw.match?(/\A\d+\z/)

    match = raw.match(/\A(\d+)([mhd])\z/)
    raise Error, 'Use minutos inteiros ou sufixos como 15m, 2h, 1d.' unless match

    amount = match[1].to_i
    unit = match[2]
    multiplier = { 'm' => 60, 'h' => 3600, 'd' => 86_400 }.fetch(unit)
    amount * multiplier
  end

  def self.parse_repeat(value)
    repeat = value.to_s.strip.downcase
    return repeat if %w[daily weekly monthly].include?(repeat)

    raise Error, 'Use daily, weekly ou monthly para repeticao.'
  end

  def self.now_local
    time_source.call
  end

  def self.isoformat_local(value)
    value.strftime('%Y-%m-%dT%H:%M:%S')
  end

  def self.label_for(reminder_id, phase)
    "com.codex.reminder.#{reminder_id}.#{phase}"
  end

  def self.plist_path(label)
    File.join(launch_agents_dir, "#{label}.plist")
  end

  def self.uid_domain
    "gui/#{Process.uid}"
  end

  def self.run_command(*args)
    stdout, stderr, status = Open3.capture3(*args.flatten)
    [(stdout + stderr), status.exitstatus]
  end

  def self.command_available?(command)
    _output, status = run_command('which', command)
    status.zero?
  end

  def self.bootout_label(label)
    run_command('launchctl', 'bootout', "#{uid_domain}/#{label}")
  end

  def self.bootstrap_plist(path)
    label = File.basename(path, '.plist')
    bootout_label(label)
    output, status = run_command('launchctl', 'bootstrap', uid_domain, path)
    return if status.zero?
    return if output.downcase.include?('service already loaded')

    raise Error, (output.strip.empty? ? 'Falha ao registrar launch agent.' : output.strip)
  end

  def self.delete_plist(label)
    bootout_label(label)
    path = plist_path(label)
    FileUtils.rm_f(path)
  end

  def self.create_launch_agent(reminder_id, at_time, phase)
    raise Error, "Script do reminder nao e executavel: #{script_path}" unless File.executable?(script_path)

    label = label_for(reminder_id, phase)
    path = plist_path(label)
    File.write(path, launch_agent_plist(label, reminder_id, at_time, phase))
    bootstrap_plist(path)
    label
  end

  def self.xml_escape(value)
    value.to_s
         .gsub('&', '&amp;')
         .gsub('<', '&lt;')
         .gsub('>', '&gt;')
         .gsub('"', '&quot;')
         .gsub("'", '&apos;')
  end

  def self.plist_array(values)
    values.map { |value| "    <string>#{xml_escape(value)}</string>" }.join("\n")
  end

  def self.launch_agent_plist(label, reminder_id, at_time, phase)
    <<~XML
      <?xml version="1.0" encoding="UTF-8"?>
      <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
      <plist version="1.0">
      <dict>
        <key>Label</key>
        <string>#{xml_escape(label)}</string>
        <key>ProgramArguments</key>
        <array>
      #{plist_array([script_path, '_trigger', reminder_id, phase])}
        </array>
        <key>StartCalendarInterval</key>
        <dict>
          <key>Month</key>
          <integer>#{at_time.month}</integer>
          <key>Day</key>
          <integer>#{at_time.day}</integer>
          <key>Hour</key>
          <integer>#{at_time.hour}</integer>
          <key>Minute</key>
          <integer>#{at_time.min}</integer>
        </dict>
        <key>RunAtLoad</key>
        <false/>
        <key>StandardOutPath</key>
        <string>#{xml_escape(File.join(app_dir, "#{label}.out.log"))}</string>
        <key>StandardErrorPath</key>
        <string>#{xml_escape(File.join(app_dir, "#{label}.err.log"))}</string>
      </dict>
      </plist>
    XML
  end

  def self.apple_script_string(value)
    "\"#{value.to_s.gsub('\\', '\\\\\\').gsub('"', '\"')}\""
  end

  def self.send_terminal_notification(title, subtitle, message)
    output, status = run_command(
      'terminal-notifier',
      '-title', title.to_s,
      '-subtitle', subtitle.to_s,
      '-message', message.to_s,
      '-sound', 'Glass',
      '-group', 'com.codex.reminder'
    )
    return if status.zero?

    error_message = output.strip.empty? ? 'Falha ao enviar notificacao via terminal-notifier.' : output.strip
    raise Error, error_message
  end

  def self.send_apple_script_notification(title, subtitle, message)
    # Fallback nativo do macOS quando terminal-notifier nao estiver instalado.
    script = [
      'display notification',
      apple_script_string(message),
      'with title',
      apple_script_string(title),
      'subtitle',
      apple_script_string(subtitle),
      'sound name "Glass"'
    ].join(' ')
    output, status = run_command('osascript', '-e', script)
    raise Error, (output.strip.empty? ? 'Falha ao enviar notificacao no macOS.' : output.strip) unless status.zero?
  end

  def self.send_notification(title, subtitle, message)
    if command_available?('terminal-notifier')
      send_terminal_notification(title, subtitle, message)
    else
      send_apple_script_notification(title, subtitle, message)
    end
  end

  def self.find_reminder(items, reminder_id)
    index = items.find_index { |item| item['id'] == reminder_id }
    [index, index ? items[index] : nil]
  end

  def self.cleanup_reminder_jobs(reminder)
    %w[main_label warn_label].each do |key|
      label = reminder[key]
      delete_plist(label) if label
    end
  end

  def self.human_delta(seconds)
    return "#{seconds / 86_400} dia" if seconds == 86_400
    return "#{seconds / 86_400} dias" if seconds.positive? && (seconds % 86_400).zero?
    return "#{seconds / 3600} hora" if seconds == 3600
    return "#{seconds / 3600} horas" if seconds.positive? && (seconds % 3600).zero?
    return '1 minuto' if seconds == 60

    "#{seconds / 60} minutos"
  end

  def self.next_scheduled_at(scheduled_at, repeat)
    case repeat
    when 'daily'
      scheduled_at + 86_400
    when 'weekly'
      scheduled_at + (7 * 86_400)
    when 'monthly'
      next_month_date = Date.new(scheduled_at.year, scheduled_at.month, 1) >> 1
      last_day = Date.new(next_month_date.year, next_month_date.month, -1).day
      day = [scheduled_at.day, last_day].min
      Time.new(
        next_month_date.year, next_month_date.month, day,
        scheduled_at.hour, scheduled_at.min, scheduled_at.sec, scheduled_at.utc_offset
      )
    else
      raise Error, "Repeticao invalida: #{repeat}"
    end
  end

  def self.reschedule_recurring_reminder(reminder)
    scheduled_at = Time.parse(reminder['scheduled_at'])
    next_at = next_scheduled_at(scheduled_at, reminder['repeat'])
    warning_seconds = reminder['warning_seconds'].to_i
    warning_at = warning_seconds.positive? ? next_at - warning_seconds : nil

    cleanup_reminder_jobs(reminder)

    reminder['scheduled_at'] = isoformat_local(next_at)
    reminder['warning_at'] = warning_at ? isoformat_local(warning_at) : nil
    reminder['main_label'] = create_launch_agent(reminder['id'], next_at, 'main')
    reminder['warn_label'] = warning_at ? create_launch_agent(reminder['id'], warning_at, 'warn') : nil
    reminder
  end

  def self.print_add_summary(stdout, reminder, scheduled_at, warning_at, warn_value)
    stdout.puts "Reminder criado: #{reminder['id']}"
    stdout.puts "Texto: #{reminder['text']}"
    stdout.puts "Horario: #{scheduled_at.strftime('%Y-%m-%d %H:%M')}"
    if reminder['warning_seconds'].positive?
      stdout.puts "Aviso previo: #{warning_at.strftime('%Y-%m-%d %H:%M')} (#{warn_value} antes)"
    end
    stdout.puts "Repeticao: #{reminder['repeat']}" if reminder['repeat']
  end

  def self.add_command(argv, stdout: $stdout)
    options = {}
    parser = OptionParser.new do |opts|
      opts.banner = [
        'Uso: ./reminder add --text "..." --at "YYYY-MM-DD HH:MM"',
        '[--warn 15m] [--repeat daily|weekly|monthly]'
      ].join(' ')
      opts.on('--text TEXT', 'Texto da notificacao') { |value| options[:text] = value }
      opts.on('--at DATETIME', 'Horario: YYYY-MM-DD HH:MM') { |value| options[:at] = value }
      opts.on('--warn DURATION', 'Aviso previo: 15, 15m, 2h, 1d') { |value| options[:warn] = value }
      opts.on('--repeat REPEAT', 'Repeticao: daily, weekly, monthly') { |value| options[:repeat] = value }
    end
    parser.parse!(argv)

    raise Error, parser.to_s unless options[:text] && options[:at]

    scheduled_at = parse_datetime(options[:at])
    raise Error, 'O horario precisa estar no futuro.' unless scheduled_at > now_local

    warning_seconds = options[:warn] ? parse_duration(options[:warn]) : 0
    repeat = options[:repeat] ? parse_repeat(options[:repeat]) : nil
    warning_at = scheduled_at - warning_seconds
    if warning_seconds.positive? && warning_at <= now_local
      raise Error, 'O aviso previo cai no passado. Use um intervalo menor.'
    end

    items = load_db
    reminder_id = id_generator.call
    main_label = create_launch_agent(reminder_id, scheduled_at, 'main')
    warn_label = warning_seconds.positive? ? create_launch_agent(reminder_id, warning_at, 'warn') : nil

    reminder = {
      'id' => reminder_id,
      'text' => options[:text].strip,
      'scheduled_at' => isoformat_local(scheduled_at),
      'warning_seconds' => warning_seconds,
      'warning_at' => warning_seconds.positive? ? isoformat_local(warning_at) : nil,
      'repeat' => repeat,
      'created_at' => isoformat_local(now_local),
      'main_label' => main_label,
      'warn_label' => warn_label
    }

    items << reminder
    save_db(items)

    print_add_summary(stdout, reminder, scheduled_at, warning_at, options[:warn])
    reminder
  end

  def self.list_command(_argv, stdout: $stdout)
    items = load_db.sort_by { |item| item['scheduled_at'] }
    if items.empty?
      stdout.puts 'Nenhum reminder ativo.'
      return []
    end

    items.each do |item|
      warn_suffix = item['warning_at'] ? " | aviso: #{item['warning_at'].tr('T', ' ')}" : ''
      repeat_suffix = item['repeat'] ? " | repete: #{item['repeat']}" : ''
      stdout.puts "#{item['id']} | #{item['scheduled_at'].tr('T', ' ')}#{warn_suffix}#{repeat_suffix} | #{item['text']}"
    end
    items
  end

  def self.remove_command(argv, stdout: $stdout)
    reminder_id = argv.first
    raise Error, 'Uso: ./reminder remove <id>' if reminder_id.nil? || reminder_id.empty?

    items = load_db
    index, reminder = find_reminder(items, reminder_id)
    raise Error, "Reminder nao encontrado: #{reminder_id}" unless reminder

    cleanup_reminder_jobs(reminder)
    items.delete_at(index)
    save_db(items)
    stdout.puts "Reminder removido: #{reminder_id}"
    reminder
  end

  def self.trigger_command(argv)
    reminder_id = argv[0]
    phase = argv[1]
    raise Error, 'Uso interno invalido.' unless reminder_id && %w[warn main].include?(phase)

    items = load_db
    index, reminder = find_reminder(items, reminder_id)
    unless reminder
      delete_plist(label_for(reminder_id, phase))
      return nil
    end

    scheduled_at = Time.parse(reminder['scheduled_at'])
    if phase == 'warn'
      warning_at = Time.parse(reminder['warning_at'])
      warn_message = "#{reminder['text']} em #{human_delta((scheduled_at - warning_at).to_i)}."
      send_notification(APP_TITLE, 'Aviso previo', warn_message)
      delete_plist(reminder['warn_label'])
      reminder['warn_label'] = nil
      items[index] = reminder
      save_db(items)
      return reminder
    end

    send_notification(APP_TITLE, 'Agora', reminder['text'])
    if reminder['repeat']
      reminder = reschedule_recurring_reminder(reminder)
      items[index] = reminder
      save_db(items)
      return reminder
    end

    cleanup_reminder_jobs(reminder)
    items.delete_at(index)
    save_db(items)
    reminder
  end

  def self.usage
    <<~TEXT
      Uso:
        ./reminder add --text "..." --at "YYYY-MM-DD HH:MM" [--warn 15m] [--repeat daily|weekly|monthly]
        ./reminder list
        ./reminder remove <id>
    TEXT
  end

  def self.run(argv = ARGV, stdout: $stdout, stderr: $stderr)
    ensure_dirs

    command = argv.shift
    case command
    when 'add'
      add_command(argv, stdout: stdout)
      0
    when 'list'
      list_command(argv, stdout: stdout)
      0
    when 'remove'
      remove_command(argv, stdout: stdout)
      0
    when '_trigger'
      trigger_command(argv)
      0
    else
      stdout.puts usage
      command.nil? ? 0 : 1
    end
  rescue Error, OptionParser::ParseError => e
    stderr.puts e.message
    1
  end
end
