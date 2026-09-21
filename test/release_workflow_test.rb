# Run with: ruby test/release_workflow_test.rb
require 'yaml'
require 'open3'
require 'tmpdir'
require 'fileutils'

WORKFLOW = YAML.load_file(File.expand_path('../.github/workflows/release.yml', __dir__))
JOBS = WORKFLOW.fetch('jobs')

def assert(condition, message)
  raise message unless condition
end

def step(job, name)
  JOBS.fetch(job).fetch('steps').find { |entry| entry['name'] == name } || raise("Missing step: #{name}")
end

def script(job, name)
  step(job, name).fetch('run')
end

def shell(code, env, directory)
  Open3.capture3(env, 'bash', '-e', '-o', 'pipefail', '-c', code, chdir: directory)
end

def check_success(result, expected, label)
  stdout, stderr, status = result
  assert(status.success? == expected, "#{label}: exit #{status.exitstatus}\n#{stdout}\n#{stderr}")
end

tests = 0
run = lambda do |name, &block|
  block.call
  tests += 1
  puts "PASS: #{name}"
end

run.call('safe defaults and publication gates') do
  trigger = WORKFLOW['on'] || WORKFLOW[true] # Psych's YAML 1.1 parser treats on as true.
  inputs = trigger.fetch('workflow_call').fetch('inputs')
  assert(inputs.fetch('publish').fetch('default') == false, 'Publishing must be opt-in')
  condition = JOBS.fetch('release').fetch('if')
  assert(condition.include?('inputs.publish'), 'Missing publish gate')
  assert(condition.include?("github.event_name == 'push'"), 'Pull requests must not publish')
  assert(condition.include?("github.ref == format('refs/heads/{0}', inputs.release-branch)"), 'Missing branch gate')
  assert(JOBS['release']['environment'] == 'Release', 'Missing environment gate')
  assert(JOBS['release']['needs'] == 'archive', 'Release must wait for the build')
  assert(JOBS['archive']['permissions'] == { 'contents' => 'read' }, 'Build must be read-only')
  assert(JOBS['release']['permissions'] == { 'contents' => 'write' }, 'Release must only request contents: write')
end

run.call('caller example scopes write access to the reusable-workflow job') do
  caller = YAML.load_file(File.expand_path('../examples/release.yml', __dir__))
  assert(caller['permissions'] == { 'contents' => 'read' }, 'Caller defaults must be read-only')
  assert(caller['jobs']['profile']['permissions'] == { 'contents' => 'write' }, 'Only the calling job may request write access')
end

run.call('pinned actions, caller checkout, and build-once publication') do
  JOBS.each_value do |job|
    job.fetch('steps').each do |entry|
      next unless entry['uses']
      assert(entry['uses'].match?(/@[0-9a-f]{40}\z/), "Unpinned action: #{entry['uses']}")
      if entry['uses'].start_with?('actions/checkout@')
        assert(entry['with']['ref'] == '${{ github.sha }}', 'Checkout must use the original build commit')
        assert(entry['with']['persist-credentials'] == false, 'Checkout must not persist credentials')
      end
    end
  end
  release_scripts = JOBS['release']['steps'].map { |entry| entry['run'] }.compact.join("\n")
  assert(!release_scripts.include?('bundle '), 'Publication must not install or rebuild')
  upload = step('archive', 'Upload archive for testing')
  download = step('release', 'Download checked archive')
  assert(upload['with']['name'] == download['with']['name'], 'Artifact names differ')
  assert(!download['with'].key?('run-id'), 'Download must use the same workflow run')
  assert(!download['with'].key?('github-token'), 'Same-run download must not use a GitHub API token')
  assert(!download['with'].key?('repository'), 'Download must use the calling repository')
end

run.call('all embedded shell scripts parse') do
  JOBS.each_value do |job|
    job.fetch('steps').each do |entry|
      next unless entry['run']
      _, err, status = Open3.capture3('bash', '-n', stdin_data: entry['run'])
      assert(status.success?, "#{entry['name']}: #{err}")
    end
  end
end

Dir.mktmpdir('profile-workflow-tests-') do |directory|
  env = {
    'AUDITOR' => 'cinc-auditor',
    'GITHUB_ENV' => File.join(directory, 'env'),
    'GITHUB_OUTPUT' => File.join(directory, 'output'),
    'RUNNER_TEMP' => directory,
    'ARCHIVE' => 'sample-1.2.3.tar.gz',
    'RELEASE_TAG' => 'v1.2.3',
    'GH_REPO' => 'example/profile'
  }
  metadata = { 'name' => 'sample', 'version' => '1.2.3' }
  cases = [
    ['standalone profile', metadata, 'cinc-auditor', true, false],
    ['InSpec runtime', metadata, 'inspec', true, false],
    ['profile with dependencies', metadata.merge('depends' => [{ 'name' => 'parent', 'url' => 'https://example.invalid/parent.tar.gz' }]), 'cinc-auditor', true, true],
    ['empty dependencies', metadata.merge('depends' => []), 'cinc-auditor', true, false],
    ['null dependencies', metadata.merge('depends' => nil), 'cinc-auditor', true, false],
    ['unsafe filename', metadata.merge('name' => '../sample'), 'cinc-auditor', false, nil],
    ['newline in name', metadata.merge('name' => "sample\nINJECTED=value"), 'cinc-auditor', false, nil],
    ['option-like name', metadata.merge('name' => '--sample'), 'cinc-auditor', false, nil],
    ['missing version', { 'name' => 'sample' }, 'cinc-auditor', false, nil],
    ['invalid version', metadata.merge('version' => '1.2'), 'cinc-auditor', false, nil],
    ['prerelease version', metadata.merge('version' => '1.2.3-rc1'), 'cinc-auditor', false, nil],
    ['invalid dependencies', metadata.merge('depends' => 'parent'), 'cinc-auditor', false, nil],
    ['invalid executable', metadata, 'inspec; echo injected', false, nil]
  ]
  cases.each do |name, data, auditor, success, depends|
    run.call("metadata: #{name}") do
      File.write(File.join(directory, 'inspec.yml'), YAML.dump(data))
      File.write(env['GITHUB_ENV'], '')
      File.write(env['GITHUB_OUTPUT'], '')
      result = shell(script('archive', 'Check profile metadata'), env.merge('AUDITOR' => auditor), directory)
      check_success(result, success, name)
      if success
        outputs = File.read(env['GITHUB_OUTPUT'])
        assert(outputs == "archive=sample-1.2.3.tar.gz\ntag=v1.2.3\nhas_dependencies=#{depends}\n", 'Incorrect metadata outputs')
        assert(File.read(env['GITHUB_ENV']) == "ARCHIVE=sample-1.2.3.tar.gz\n", 'Incorrect archive environment')
      else
        assert(File.read(env['GITHUB_OUTPUT']).empty?, 'Invalid input produced workflow outputs')
      end
    end
  end

  FileUtils.mkdir_p(File.join(directory, 'release'))
  [
    ['no dependencies', false, false, false, true],
    ['vendored dependencies', true, true, true, true],
    ['missing vendor', true, true, false, false],
    ['missing lockfile', true, false, true, false]
  ].each do |name, depends, lock, vendor, success|
    run.call("archive check: #{name}") do
      Dir.mktmpdir('archive-fixture-') do |fixture|
        File.write(File.join(fixture, 'inspec.yml'), YAML.dump(metadata))
        File.write(File.join(fixture, 'inspec.lock'), 'fixture lock') if lock
        if vendor
          FileUtils.mkdir_p(File.join(fixture, 'vendor', 'parent'))
          File.write(File.join(fixture, 'vendor', 'parent', 'inspec.yml'), 'name: parent')
        end
        _, err, status = Open3.capture3('tar', '-czf', File.join(directory, 'release', env['ARCHIVE']), '-C', fixture, '.')
        assert(status.success?, err)
      end
      code = "bundle() { return 0; }\n" + script('archive', 'Check the archived Profile')
      check_success(shell(code, env.merge('HAS_DEPENDENCIES' => depends.to_s), directory), success, name)
    end
  end

  run.call('auditor validation failure prevents publication artifact') do
    code = "bundle() { return 1; }\n" + script('archive', 'Check the archived Profile')
    check_success(shell(code, env.merge('HAS_DEPENDENCIES' => 'false'), directory), false, 'auditor failure')
  end

  run.call('checksum round-trip and tamper detection') do
    # macOS provides shasum; Linux runners provide sha256sum.
    portable_checksum = "if ! command -v sha256sum >/dev/null; then sha256sum() { shasum -a 256 \"$@\"; }; fi\n"
    check_success(shell(portable_checksum + script('archive', 'Generate checksum'), env, directory), true, 'checksum creation')
    check_success(shell(portable_checksum + script('release', 'Verify downloaded archive'), env, directory), true, 'checksum verification')
    File.open(File.join(directory, 'release', env['ARCHIVE']), 'a') { |file| file.write('tampered') }
    check_success(shell(portable_checksum + script('release', 'Verify downloaded archive'), env, directory), false, 'tampered archive')
  end

  [['configured reviewers', 'true', '0', true], ['no reviewers', 'false', '0', false], ['API denied', '', '1', false]].each do |name, protection, api_status, success|
    run.call("approval protection: #{name}") do
      stub = "gh() { printf '%s\\n' \"$PROTECTION\"; return \"$API_STATUS\"; }\n"
      result = shell(stub + script('release', 'Require configured approval protection'),
                     env.merge('PROTECTION' => protection, 'API_STATUS' => api_status), directory)
      check_success(result, success, name)
    end
  end

  [['no existing tag', false, 'abc', true], ['tag matches build', true, 'abc', true], ['tag points elsewhere', true, 'def', false]].each do |name, exists, commit, success|
    run.call("tag guard: #{name}") do
      stub = <<~SH
        git() {
          case "$1" in
            show-ref) return "$TAG_STATUS" ;;
            rev-parse) printf '%s\\n' "$TAG_COMMIT" ;;
            *) return 99 ;;
          esac
        }
      SH
      result = shell(stub + script('release', 'Check existing release tag'),
                     env.merge('GITHUB_SHA' => 'abc', 'TAG_STATUS' => exists ? '0' : '1', 'TAG_COMMIT' => commit), directory)
      check_success(result, success, name)
    end
  end

  run.call('release attaches the checked asset and checksum to the original commit') do
    stub = "gh() { printf '%s\\n' \"$@\"; }\n"
    stdout, stderr, status = shell(stub + script('release', 'Create release'), env.merge('GITHUB_SHA' => 'abc'), directory)
    assert(status.success?, stderr)
    expected = ['release', 'create', 'v1.2.3', File.join(directory, 'release', env['ARCHIVE']),
                File.join(directory, 'release', env['ARCHIVE'] + '.sha256'),
                '--target', 'abc', '--title', 'v1.2.3', '--generate-notes']
    assert(stdout.lines.map(&:chomp) == expected, 'Incorrect gh release arguments')
  end
end

puts "#{tests} tests passed."
