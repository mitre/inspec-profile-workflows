# Run with: ruby test/release_workflow_test.rb
require 'yaml'
require 'open3'
require 'tmpdir'
require 'fileutils'
require 'json'

WORKFLOW = YAML.load_file(File.expand_path('../.github/workflows/release.yml', __dir__))
PUBLISH = YAML.load_file(File.expand_path('../.github/workflows/publish.yml', __dir__))
JOBS = WORKFLOW.fetch('jobs').merge(PUBLISH.fetch('jobs'))

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

run.call('automatic builds have no publishing job or environment') do
  assert(WORKFLOW['jobs'].keys == ['archive'], 'Build workflow must only build')
  assert(JOBS['archive']['permissions'] == { 'contents' => 'read' }, 'Build must be read-only')
  assert(!JOBS['archive'].key?('environment'), 'Build must not request approval')
  trigger = WORKFLOW['on'] || WORKFLOW[true]
  assert(!trigger['workflow_call']['inputs'].key?('publish'), 'Build must not have a publish switch')
end

run.call('manual publication validates before approval and limits permissions') do
  assert(PUBLISH['jobs'].keys == ['validate', 'release'], 'Publication jobs changed')
  assert(JOBS['release']['needs'] == 'validate', 'Validate selected build before approval')
  assert(JOBS['release']['environment'] == 'Release', 'Missing environment gate')
  assert(!JOBS['validate'].key?('environment'), 'Preflight must not request approval')
  assert(JOBS['validate']['permissions'] == { 'contents' => 'read', 'actions' => 'read' }, 'Preflight must be read-only')
  assert(JOBS['release']['permissions'] == { 'contents' => 'write', 'actions' => 'read' }, 'Publication requires release and cross-run artifact permissions')
end

run.call('caller examples separate automatic builds and manual publication') do
  build = YAML.load_file(File.expand_path('../examples/release.yml', __dir__))
  publish = YAML.load_file(File.expand_path('../examples/publish.yml', __dir__))
  assert(build['permissions'] == { 'contents' => 'read' }, 'Build caller must be read-only')
  assert(!build['jobs']['profile'].key?('permissions'), 'Build caller must not elevate permissions')
  build_trigger = build['on'] || build[true]
  assert(build_trigger.keys.sort == ['pull_request', 'push'], 'Build caller triggers changed')
  publish_trigger = publish['on'] || publish[true]
  assert(publish_trigger.keys == ['workflow_dispatch'], 'Publication must only be manually triggered')
  assert(publish['jobs']['publish']['permissions'] == { 'contents' => 'write', 'actions' => 'read' }, 'Publication caller permissions changed')
  assert(publish['jobs']['publish']['with']['build-workflow'] == 'release.yml', 'Expected caller workflow changed')
end

run.call('pinned actions, original commit checkout, and no rebuild on publication') do
  expected_refs = {
    'archive' => '${{ github.sha }}',
    'validate' => '${{ steps.source.outputs.build_sha }}',
    'release' => '${{ needs.validate.outputs.build_sha }}'
  }
  JOBS.each do |job_id, job|
    job.fetch('steps').each do |entry|
      next unless entry['uses']
      assert(entry['uses'].match?(/@[0-9a-f]{40}\z/), "Unpinned action: #{entry['uses']}")
      if entry['uses'].start_with?('actions/checkout@')
        assert(entry['with']['ref'] == expected_refs.fetch(job_id), 'Checkout must use the correct source commit')
        assert(entry['with']['persist-credentials'] == false, 'Checkout must not persist credentials')
      end
    end
  end
  publish_scripts = PUBLISH['jobs'].values.flat_map { |job| job['steps'].map { |entry| entry['run'] } }.compact.join("\n")
  assert(!publish_scripts.include?('bundle '), 'Publication must not install or rebuild the profile')
  download = step('release', 'Download checked archive')['with']
  assert(download['artifact-ids'] == '${{ needs.validate.outputs.artifact_id }}', 'Download must pin the validated immutable artifact ID')
  assert(download['run-id'] == '${{ needs.validate.outputs.build_run_id }}', 'Download must use the resolved build, never reselect latest after approval')
  assert(download['github-token'] == '${{ github.token }}', 'Cross-run download requires a token')
  assert(download['repository'] == '${{ github.repository }}', 'Download must stay in the calling repository')
  assert(download['merge-multiple'] == true, 'Artifact must extract directly into the release directory')
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
  run.call('build and publication summaries show the exact selected source') do
    summary = File.join(directory, 'summary')
    summary_env = env.merge('GITHUB_STEP_SUMMARY' => summary, 'GITHUB_RUN_ID' => '123',
                            'GITHUB_SHA' => 'dispatch-commit', 'BUILD_SHA' => 'build-commit',
                            'BUILD_RUN_ID' => '456', 'ARTIFACT_ID' => '987', 'GITHUB_SERVER_URL' => 'https://github.com')
    [['archive', 'Build summary'], ['validate', 'Publication request summary']].each do |job, name|
      result = shell(script(job, name), summary_env, directory)
      check_success(result, true, name)
      assert(result[1].empty?, 'Summary must not attempt to execute its displayed values')
    end
    content = File.read(summary)
    ['Archive: sample-1.2.3.tar.gz', 'Build run ID: 123', 'Release: v1.2.3',
     'Build: https://github.com/example/profile/actions/runs/456',
     'Original commit: build-commit', 'Artifact ID: 987'].each do |text|
      assert(content.include?(text), "Missing summary detail: #{text}")
    end
  end

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
                     env.merge('GITHUB_SHA' => 'different-dispatch-commit', 'BUILD_SHA' => 'abc', 'TAG_STATUS' => exists ? '0' : '1', 'TAG_COMMIT' => commit), directory)
      check_success(result, success, name)
    end
  end

  run.call('release attaches the checked asset and checksum to the original commit') do
    stub = "gh() { printf '%s\\n' \"$@\"; }\n"
    stdout, stderr, status = shell(stub + script('release', 'Create release'), env.merge('GITHUB_SHA' => 'different-dispatch-commit', 'BUILD_SHA' => 'abc'), directory)
    assert(status.success?, stderr)
    expected = ['release', 'create', 'v1.2.3', File.join(directory, 'release', env['ARCHIVE']),
                File.join(directory, 'release', env['ARCHIVE'] + '.sha256'),
                '--target', 'abc', '--title', 'v1.2.3', '--generate-notes']
    assert(stdout.lines.map(&:chomp) == expected, 'Incorrect gh release arguments')
  end
end


Dir.mktmpdir('publication-validation-') do |directory|
  env = {
    'GH_REPO' => 'example/profile',
    'BUILD_RUN_ID' => '123',
    'BUILD_WORKFLOW' => 'release.yml',
    'RELEASE_BRANCH' => 'main',
    'GITHUB_EVENT_NAME' => 'workflow_dispatch',
    'GITHUB_REF' => 'refs/heads/main',
    'RUNNER_TEMP' => directory,
    'GITHUB_OUTPUT' => File.join(directory, 'output'),
    'GITHUB_ENV' => File.join(directory, 'env'),
    'RUN_FIXTURE' => File.join(directory, 'run.json'),
    'WORKFLOW_FIXTURE' => File.join(directory, 'workflow.json'),
    'ARTIFACT_FIXTURE' => File.join(directory, 'artifacts.json')
  }

  [
    ['manual request', {}, true],
    ['optional run ID', { 'BUILD_RUN_ID' => '' }, true],
    ['push cannot request publication', { 'GITHUB_EVENT_NAME' => 'push' }, false],
    ['PR cannot request publication', { 'GITHUB_EVENT_NAME' => 'pull_request' }, false],
    ['dispatch from other branch', { 'GITHUB_REF' => 'refs/heads/feature' }, false],
    ['non-numeric run ID', { 'BUILD_RUN_ID' => '../123' }, false],
    ['zero run ID', { 'BUILD_RUN_ID' => '0' }, false],
    ['workflow path instead of filename', { 'BUILD_WORKFLOW' => '../release.yml' }, false],
    ['invalid workflow extension', { 'BUILD_WORKFLOW' => 'release.txt' }, false]
  ].each do |name, changes, success|
    run.call("request validation: #{name}") do
      check_success(shell(script('validate', 'Validate publication request'), env.merge(changes), directory), success, name)
    end
  end

  [
    ['latest successful build', '', [{ 'id' => 123 }], true],
    ['no successful build', '', [], false],
    ['invalid latest run ID', '', [{ 'id' => "123\ninjected=value" }], false],
    ['explicit build skips lookup', '456', [], true]
  ].each do |name, requested_id, candidates, success|
    run.call("build selection: #{name}") do
      candidate_file = File.join(directory, 'candidates.json')
      query_file = File.join(directory, 'query.txt')
      File.write(candidate_file, JSON.generate({ 'workflow_runs' => candidates }))
      File.write(query_file, '')
      File.write(env['GITHUB_OUTPUT'], '')
      File.write(env['GITHUB_ENV'], '')
      stub = "gh() { printf '%s\\n' \"$@\" > \"$QUERY_FILE\"; cat \"$CANDIDATE_FILE\"; }\n"
      selected_env = env.merge('BUILD_RUN_ID' => requested_id, 'CANDIDATE_FILE' => candidate_file, 'QUERY_FILE' => query_file)
      result = shell(stub + script('validate', 'Select source build'), selected_env, directory)
      check_success(result, success, name)
      selected_id = requested_id.empty? ? '123' : requested_id
      expected = success ? "build_run_id=#{selected_id}\n" : ''
      assert(File.read(env['GITHUB_OUTPUT']) == expected, 'Incorrect selected run output')
      assert(File.read(env['GITHUB_ENV']) == (success ? "BUILD_RUN_ID=#{selected_id}\n" : ''), 'Selected run must persist for validation')
      if requested_id.empty?
        args = File.read(query_file).lines.map(&:chomp)
        assert(args == ['api', '--method', 'GET', 'repos/example/profile/actions/workflows/release.yml/runs',
                        '-f', 'branch=main', '-f', 'event=push', '-f', 'status=success', '-f', 'per_page=1'], 'Latest query must filter workflow, branch, event, and success')
      else
        assert(File.read(query_file).empty?, 'Explicit run must not query latest')
      end
    end
  end

  run.call('latest-build API failure stops selection') do
    File.write(env['GITHUB_OUTPUT'], '')
    result = shell("gh() { return 1; }\n" + script('validate', 'Select source build'), env.merge('BUILD_RUN_ID' => ''), directory)
    check_success(result, false, 'latest-build API unavailable')
    assert(File.read(env['GITHUB_OUTPUT']).empty?, 'Failed lookup must not select a build')
  end

  source = {
    'id' => 123, 'workflow_id' => 77, 'path' => '.github/workflows/release.yml',
    'repository' => { 'full_name' => 'example/profile' },
    'head_repository' => { 'full_name' => 'example/profile' },
    'event' => 'push', 'head_branch' => 'main', 'status' => 'completed', 'conclusion' => 'success',
    'head_sha' => 'a' * 40
  }
  workflow = { 'id' => 77, 'path' => '.github/workflows/release.yml' }
  artifact = { 'id' => 987, 'name' => 'release-profile', 'expired' => false,
               'workflow_run' => { 'id' => 123, 'head_sha' => 'a' * 40 } }
  stub = <<~SH
    gh() {
      case "$*" in
        *"/artifacts?"*) cat "$ARTIFACT_FIXTURE" ;;
        *"/actions/workflows/"*) cat "$WORKFLOW_FIXTURE" ;;
        *"/actions/runs/"*) cat "$RUN_FIXTURE" ;;
        *) return 99 ;;
      esac
    }
  SH
  scenarios = [
    ['valid build', {}, workflow, [artifact], true],
    ['wrong run ID', { 'id' => 456 }, workflow, [artifact], false],
    ['foreign repository', { 'repository' => { 'full_name' => 'other/profile' } }, workflow, [artifact], false],
    ['fork source', { 'head_repository' => { 'full_name' => 'fork/profile' } }, workflow, [artifact], false],
    ['wrong workflow ID', { 'workflow_id' => 78 }, workflow, [artifact], false],
    ['wrong workflow path', {}, workflow.merge('path' => '.github/workflows/other.yml'), [artifact], false],
    ['wrong run path', { 'path' => '.github/workflows/other.yml' }, workflow, [artifact], false],
    ['PR build', { 'event' => 'pull_request' }, workflow, [artifact], false],
    ['other branch build', { 'head_branch' => 'feature' }, workflow, [artifact], false],
    ['running build', { 'status' => 'in_progress' }, workflow, [artifact], false],
    ['failed build', { 'conclusion' => 'failure' }, workflow, [artifact], false],
    ['invalid commit', { 'head_sha' => "abc\ninjected=value" }, workflow, [artifact], false],
    ['missing artifact', {}, workflow, [], false],
    ['duplicate artifacts', {}, workflow, [artifact, artifact.merge('id' => 988)], false],
    ['expired artifact', {}, workflow, [artifact.merge('expired' => true)], false],
    ['artifact from other run', {}, workflow, [artifact.merge('workflow_run' => { 'id' => 456, 'head_sha' => 'a' * 40 })], false],
    ['artifact from other commit', {}, workflow, [artifact.merge('workflow_run' => { 'id' => 123, 'head_sha' => 'b' * 40 })], false],
    ['invalid artifact ID', {}, workflow, [artifact.merge('id' => "987\ninjected=value")], false]
  ]
  scenarios.each do |name, changes, workflow_data, artifacts, success|
    run.call("source validation: #{name}") do
      File.write(env['RUN_FIXTURE'], JSON.generate(source.merge(changes)))
      File.write(env['WORKFLOW_FIXTURE'], JSON.generate(workflow_data))
      # Cover pagination: matching artifact is on a later page.
      File.write(env['ARTIFACT_FIXTURE'], JSON.generate([{ 'artifacts' => [] }, { 'artifacts' => artifacts }]))
      File.write(env['GITHUB_OUTPUT'], '')
      result = shell(stub + script('validate', 'Validate source run and artifact'), env, directory)
      check_success(result, success, name)
      expected = success ? "build_sha=#{'a' * 40}\nartifact_id=987\n" : ''
      assert(File.read(env['GITHUB_OUTPUT']) == expected, 'Unexpected provenance outputs')
    end
  end

  run.call('source API failure stops validation') do
    File.write(env['GITHUB_OUTPUT'], '')
    result = shell("gh() { return 1; }\n" + script('validate', 'Validate source run and artifact'), env, directory)
    check_success(result, false, 'source API unavailable')
    assert(File.read(env['GITHUB_OUTPUT']).empty?, 'API failure must not produce outputs')
  end

  run.call('publication metadata comes from the original profile file') do
    File.write(File.join(directory, 'inspec.yml'), YAML.dump({ 'name' => 'older-profile', 'version' => '1.2.3' }))
    File.write(env['GITHUB_OUTPUT'], '')
    check_success(shell(script('validate', 'Read original profile metadata'), env, directory), true, 'original metadata')
    assert(File.read(env['GITHUB_OUTPUT']) == "archive=older-profile-1.2.3.tar.gz\ntag=v1.2.3\n", 'Incorrect original build metadata')
  end
end

puts "#{tests} tests passed."
