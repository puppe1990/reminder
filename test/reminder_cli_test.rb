# frozen_string_literal: true

require 'minitest/autorun'
require 'stringio'
require 'tmpdir'

require_relative '../lib/reminder_cli'

class ReminderCLITest < Minitest::Test
  def setup
    @tmpdir = Dir.mktmpdir('reminder-cli-test')
    @app_dir = File.join(@tmpdir, 'app')
    @launch_agents_dir = File.join(@tmpdir, 'LaunchAgents')
    @fixed_now = Time.parse('2026-04-23 13:00:00')

    ReminderCLI.app_dir = @app_dir
    ReminderCLI.launch_agents_dir = @launch_agents_dir
    ReminderCLI.script_path = '/tmp/reminder-script'
    ReminderCLI.time_source = -> { @fixed_now }
    ReminderCLI.id_generator = -> { 'fixed123' }
    ReminderCLI.ensure_dirs
  end

  def teardown
    ReminderCLI.reset_configuration!
    FileUtils.remove_entry(@tmpdir)
  end

  def with_overridden_methods(overrides)
    singleton = ReminderCLI.singleton_class
    originals = {}

    overrides.each do |name, implementation|
      originals[name] = ReminderCLI.method(name)
      singleton.define_method(name, &implementation)
    end

    yield
  ensure
    overrides.each_key do |name|
      original = originals[name]
      singleton.define_method(name) do |*args, **kwargs, &block|
        original.call(*args, **kwargs, &block)
      end
    end
  end

  def test_parse_duration_supports_minutes_hours_and_days
    assert_equal 900, ReminderCLI.parse_duration('15')
    assert_equal 900, ReminderCLI.parse_duration('15m')
    assert_equal 7200, ReminderCLI.parse_duration('2h')
    assert_equal 86_400, ReminderCLI.parse_duration('1d')
  end

  def test_parse_duration_rejects_invalid_values
    error = assert_raises(ReminderCLI::Error) { ReminderCLI.parse_duration('abc') }
    assert_match('Use minutos inteiros', error.message)
  end

  def test_parse_repeat_supports_daily_weekly_and_monthly
    assert_equal 'daily', ReminderCLI.parse_repeat('daily')
    assert_equal 'weekly', ReminderCLI.parse_repeat('weekly')
    assert_equal 'monthly', ReminderCLI.parse_repeat('monthly')
  end

  def test_parse_repeat_rejects_invalid_values
    error = assert_raises(ReminderCLI::Error) { ReminderCLI.parse_repeat('yearly') }
    assert_match('Use daily, weekly ou monthly', error.message)
  end

  def test_parse_datetime_accepts_space_and_t_separator
    assert_equal Time.parse('2026-04-23 15:00:00'), ReminderCLI.parse_datetime('2026-04-23 15:00')
    assert_equal Time.parse('2026-04-23 15:00:00'), ReminderCLI.parse_datetime('2026-04-23T15:00')
  end

  def test_launch_agent_plist_contains_expected_fields
    xml = ReminderCLI.launch_agent_plist('com.test.label', 'abc123', Time.parse('2026-04-23 15:45:00'), 'warn')

    assert_includes xml, '<string>com.test.label</string>'
    assert_includes xml, '<string>/tmp/reminder-script</string>'
    assert_includes xml, '<string>abc123</string>'
    assert_includes xml, '<string>warn</string>'
    assert_includes xml, '<integer>15</integer>'
    assert_includes xml, '<integer>45</integer>'
  end

  def test_ensure_dirs_installs_runtime_files_inside_app_dir
    ReminderCLI.reset_configuration!
    ReminderCLI.app_dir = @app_dir
    ReminderCLI.launch_agents_dir = @launch_agents_dir
    ReminderCLI.time_source = -> { @fixed_now }
    ReminderCLI.id_generator = -> { 'fixed123' }

    ReminderCLI.ensure_dirs

    assert_equal File.join(@app_dir, 'runtime', 'reminder'), ReminderCLI.script_path
    assert File.exist?(ReminderCLI.script_path)
    assert File.exist?(File.join(@app_dir, 'runtime', 'lib', 'reminder_cli.rb'))
    assert File.executable?(ReminderCLI.script_path)
  end

  def test_create_launch_agent_requires_executable_script
    ReminderCLI.script_path = '/tmp/not-executable'

    error = assert_raises(ReminderCLI::Error) do
      ReminderCLI.create_launch_agent('abc123', Time.parse('2026-04-23 15:45:00'), 'main')
    end

    assert_equal 'Script do reminder nao e executavel: /tmp/not-executable', error.message
  end

  def test_send_notification_prefers_terminal_notifier_when_available
    commands = []
    expected_command = [
      'terminal-notifier',
      '-title', 'Reminder CLI',
      '-subtitle', 'Agora',
      '-message', 'Teste visual',
      '-sound', 'Glass',
      '-group', 'com.codex.reminder'
    ]

    with_overridden_methods(
      command_available?: ->(command) { command == 'terminal-notifier' },
      run_command: lambda do |*args|
        commands << args
        ['', 0]
      end
    ) do
      ReminderCLI.send_notification('Reminder CLI', 'Agora', 'Teste visual')
    end

    assert_equal [expected_command], commands
  end

  def test_send_notification_falls_back_to_apple_script
    commands = []

    with_overridden_methods(
      command_available?: ->(_command) { false },
      run_command: lambda do |*args|
        commands << args
        ['', 0]
      end
    ) do
      ReminderCLI.send_notification('Reminder CLI', 'Agora', 'Teste visual')
    end

    assert_equal 'osascript', commands.first[0]
    assert_equal '-e', commands.first[1]
    assert_includes commands.first[2], 'display notification'
    assert_includes commands.first[2], 'Teste visual'
  end

  def test_add_command_persists_reminder_and_creates_agents
    created_agents = []
    stdout = StringIO.new

    with_overridden_methods(
      create_launch_agent: lambda do |id, at_time, phase|
        created_agents << [id, at_time.strftime('%Y-%m-%d %H:%M'), phase]
        "label-#{phase}"
      end
    ) do
      reminder = ReminderCLI.add_command(
        ['--text', 'Pagar boleto', '--at', '2026-04-23 15:00', '--warn', '30m'],
        stdout: stdout
      )

      assert_equal 'fixed123', reminder['id']
      assert_equal 'Pagar boleto', reminder['text']
      assert_equal '2026-04-23T15:00:00', reminder['scheduled_at']
      assert_equal '2026-04-23T14:30:00', reminder['warning_at']
    end

    saved = ReminderCLI.load_db
    assert_equal 1, saved.length
    assert_equal [['fixed123', '2026-04-23 15:00', 'main'], ['fixed123', '2026-04-23 14:30', 'warn']], created_agents
    assert_match('Reminder criado: fixed123', stdout.string)
    assert_match('Aviso previo: 2026-04-23 14:30 (30m antes)', stdout.string)
  end

  def test_add_command_persists_repeat_and_prints_it
    created_agents = []
    stdout = StringIO.new

    with_overridden_methods(
      create_launch_agent: lambda do |id, at_time, phase|
        created_agents << [id, at_time.strftime('%Y-%m-%d %H:%M'), phase]
        "label-#{phase}"
      end
    ) do
      reminder = ReminderCLI.add_command(
        ['--text', 'Tomar remedio', '--at', '2026-04-23 15:00', '--warn', '30m', '--repeat', 'weekly'],
        stdout: stdout
      )

      assert_equal 'weekly', reminder['repeat']
    end

    saved = ReminderCLI.load_db.first
    assert_equal 'weekly', saved['repeat']
    assert_equal [['fixed123', '2026-04-23 15:00', 'main'], ['fixed123', '2026-04-23 14:30', 'warn']], created_agents
    assert_match('Repeticao: weekly', stdout.string)
  end

  def test_add_command_rejects_warning_that_falls_in_past
    error = assert_raises(ReminderCLI::Error) do
      ReminderCLI.add_command(['--text', 'Teste', '--at', '2026-04-23 13:10', '--warn', '15m'], stdout: StringIO.new)
    end

    assert_equal 'O aviso previo cai no passado. Use um intervalo menor.', error.message
  end

  def test_list_command_prints_saved_reminders
    ReminderCLI.save_db([
                          {
                            'id' => 'a1',
                            'text' => 'Primeiro',
                            'scheduled_at' => '2026-04-23T14:00:00',
                            'warning_at' => nil,
                            'repeat' => nil
                          },
                          {
                            'id' => 'b2',
                            'text' => 'Segundo',
                            'scheduled_at' => '2026-04-23T13:30:00',
                            'warning_at' => '2026-04-23T13:15:00',
                            'repeat' => 'daily'
                          }
                        ])

    stdout = StringIO.new
    ReminderCLI.list_command([], stdout: stdout)

    lines = stdout.string.lines.map(&:strip)
    assert_equal 'b2 | 2026-04-23 13:30:00 | aviso: 2026-04-23 13:15:00 | repete: daily | Segundo', lines[0]
    assert_equal 'a1 | 2026-04-23 14:00:00 | Primeiro', lines[1]
  end

  def test_remove_command_deletes_saved_reminder_and_cleans_jobs
    ReminderCLI.save_db([
                          {
                            'id' => 'gone1',
                            'text' => 'Apagar',
                            'scheduled_at' => '2026-04-23T14:00:00',
                            'warning_at' => '2026-04-23T13:30:00',
                            'main_label' => 'label-main',
                            'warn_label' => 'label-warn'
                          }
                        ])

    deleted = []
    stdout = StringIO.new

    with_overridden_methods(delete_plist: ->(label) { deleted << label }) do
      ReminderCLI.remove_command(['gone1'], stdout: stdout)
    end

    assert_equal [], ReminderCLI.load_db
    assert_equal %w[label-main label-warn], deleted
    assert_match('Reminder removido: gone1', stdout.string)
  end

  def test_trigger_warn_sends_notification_and_keeps_main_reminder
    ReminderCLI.save_db([
                          {
                            'id' => 'warn1',
                            'text' => 'Call',
                            'scheduled_at' => '2026-04-23T15:00:00',
                            'warning_at' => '2026-04-23T14:45:00',
                            'main_label' => 'label-main',
                            'warn_label' => 'label-warn'
                          }
                        ])

    notifications = []
    deleted = []

    with_overridden_methods(
      send_notification: ->(*args) { notifications << args },
      delete_plist: ->(label) { deleted << label }
    ) do
      ReminderCLI.trigger_command(%w[warn1 warn])
    end

    saved = ReminderCLI.load_db.first
    assert_equal [['Reminder CLI', 'Aviso previo', 'Call em 15 minutos.']], notifications
    assert_equal ['label-warn'], deleted
    assert_nil saved['warn_label']
    assert_equal 'label-main', saved['main_label']
  end

  def test_trigger_main_notifies_and_removes_reminder
    ReminderCLI.save_db([
                          {
                            'id' => 'main1',
                            'text' => 'Hora da reuniao',
                            'scheduled_at' => '2026-04-23T15:00:00',
                            'warning_at' => nil,
                            'main_label' => 'label-main',
                            'warn_label' => nil
                          }
                        ])

    notifications = []
    deleted = []

    with_overridden_methods(
      send_notification: ->(*args) { notifications << args },
      delete_plist: ->(label) { deleted << label }
    ) do
      ReminderCLI.trigger_command(%w[main1 main])
    end

    assert_equal [], ReminderCLI.load_db
    assert_equal [['Reminder CLI', 'Agora', 'Hora da reuniao']], notifications
    assert_equal ['label-main'], deleted
  end

  def test_trigger_main_reschedules_daily_reminder
    ReminderCLI.save_db([
                          {
                            'id' => 'main1',
                            'text' => 'Alongar',
                            'scheduled_at' => '2026-04-23T15:00:00',
                            'warning_seconds' => 1800,
                            'warning_at' => '2026-04-23T14:30:00',
                            'repeat' => 'daily',
                            'main_label' => 'label-main',
                            'warn_label' => 'label-warn'
                          }
                        ])

    notifications = []
    deleted = []
    created_agents = []

    with_overridden_methods(
      send_notification: ->(*args) { notifications << args },
      delete_plist: ->(label) { deleted << label },
      create_launch_agent: lambda do |id, at_time, phase|
        created_agents << [id, at_time.strftime('%Y-%m-%d %H:%M'), phase]
        "new-#{phase}"
      end
    ) do
      ReminderCLI.trigger_command(%w[main1 main])
    end

    saved = ReminderCLI.load_db.first
    assert_equal [['Reminder CLI', 'Agora', 'Alongar']], notifications
    assert_equal %w[label-main label-warn], deleted
    assert_equal [['main1', '2026-04-24 15:00', 'main'], ['main1', '2026-04-24 14:30', 'warn']], created_agents
    assert_equal '2026-04-24T15:00:00', saved['scheduled_at']
    assert_equal '2026-04-24T14:30:00', saved['warning_at']
    assert_equal 'new-main', saved['main_label']
    assert_equal 'new-warn', saved['warn_label']
    assert_equal 'daily', saved['repeat']
  end

  def test_trigger_main_reschedules_monthly_reminder_to_last_valid_day
    ReminderCLI.save_db([
                          {
                            'id' => 'month1',
                            'text' => 'Fechar fatura',
                            'scheduled_at' => '2026-01-31T15:00:00',
                            'warning_seconds' => 0,
                            'warning_at' => nil,
                            'repeat' => 'monthly',
                            'main_label' => 'label-main',
                            'warn_label' => nil
                          }
                        ])

    created_agents = []

    with_overridden_methods(
      send_notification: ->(*_args) {},
      delete_plist: ->(_label) {},
      create_launch_agent: lambda do |id, at_time, phase|
        created_agents << [id, at_time.strftime('%Y-%m-%d %H:%M'), phase]
        "new-#{phase}"
      end
    ) do
      ReminderCLI.trigger_command(%w[month1 main])
    end

    saved = ReminderCLI.load_db.first
    assert_equal [['month1', '2026-02-28 15:00', 'main']], created_agents
    assert_equal '2026-02-28T15:00:00', saved['scheduled_at']
    assert_nil saved['warning_at']
    assert_equal 'monthly', saved['repeat']
  end
end
