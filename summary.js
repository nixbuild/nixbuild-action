const core = require('@actions/core');
const github = require('@actions/github');
const child_process = require('child_process');
const https = require('https');

// https://stackoverflow.com/a/18650828
function formatBytes(bytes, decimals = 2) {
  if (!+bytes) return '0 KB'
  const k = 1024
  const dm = decimals < 0 ? 0 : decimals
  const sizes = ['Bytes', 'KB', 'MB', 'GB', 'TB', 'PB', 'EB', 'ZB', 'YB']
  const i = Math.floor(Math.log(bytes) / Math.log(k))
  return `${parseFloat((bytes / Math.pow(k, i)).toFixed(dm))} ${sizes[i]}`
}

try {
  // If the shell command fails we will get an exception,
  // causing the post step to fail
  const token = JSON.parse(child_process.execSync(
    'ssh eu.nixbuild.net api tokens create --ttl-seconds 60',
    {encoding: 'utf-8'}
  )).token;

  const repository = process.env.GITHUB_REPOSITORY;
  const run_id = process.env.GITHUB_RUN_ID;
  const run_attempt = process.env.GITHUB_RUN_ATTEMPT;
  const job = process.env.GITHUB_JOB;
  const path = `/builds/summary?tags=GITHUB_REPOSITORY:${repository},GITHUB_RUN_ID:${run_id},GITHUB_RUN_ATTEMPT:${run_attempt},GITHUB_JOB:${job}`;
  const options = {
    host: 'api.nixbuild.net',
    path: path,
    method: 'GET',
    headers: {'Authorization': 'Bearer ' + token}
  };
  const request = https.request(options, function (response) {
    var body = '';
    response.on('data', function (chunk) {
      body += chunk;
    });
    response.on('end', function () {
      if (response.statusCode != 200) {
        core.setFailed(`nixbuild.net API returned: ${body}`);
      } else {
        var summary = JSON.parse(body);
        core.info(JSON.stringify(summary));
        core.summary
          .addHeading('nixbuild.net build summary')
          .addTable([
            ['&#x2714;', 'Successful builds', summary.successful_build_count.toString()],
            ['&#x274C;', 'Failed builds', summary.failed_build_count.toString()],
            ['&#x1F3F4;', 'Restarted builds', summary.discarded_build_count.toString()],
            ['&#x23F1;', 'Billable CPU hours', (summary.billable_cpu_seconds / 3600.0).toFixed(2)],
            ['&#x1F4E6;', 'Total output size', formatBytes(1024 * summary.total_output_nar_size_kilobytes)]
          ])
          .write()
      }
    });
  });
  request.on('error', function (err) {
    core.warning(`Error related to HTTPS request: ${err}`);
  });
  request.end();
} catch (error) {
  core.setFailed(error.message);
}
