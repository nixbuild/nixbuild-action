const core = require('@actions/core');
const github = require('@actions/github');
const child_process = require('child_process');
const https = require('https');
const fs = require('fs');

// https://stackoverflow.com/a/18650828
function formatBytes(bytes, decimals = 2) {
  if (!+bytes) return '0 KB'
  const k = 1024
  const dm = decimals < 0 ? 0 : decimals
  const sizes = ['Bytes', 'KB', 'MB', 'GB', 'TB', 'PB', 'EB', 'ZB', 'YB']
  const i = Math.floor(Math.log(bytes) / Math.log(k))
  return `${parseFloat((bytes / Math.pow(k, i)).toFixed(dm))} ${sizes[i]}`
}

// https://stackoverflow.com/a/15270931/410926
function basename(path) {
  return path.split(/[\\/]/).pop();
}

function generateSummary(token, allJobs) {
  const workflow = process.env.GITHUB_WORKFLOW;
  const repository = process.env.GITHUB_REPOSITORY;
  const run_id = process.env.GITHUB_RUN_ID;
  const run_attempt = process.env.GITHUB_RUN_ATTEMPT;
  const job = process.env.GITHUB_JOB;
  const invocation_id = fs.readFileSync(process.env.HOME + '/__nixbuildnet_invocation_id');
  var path = `/builds/summary?tags=GITHUB_REPOSITORY:${repository}`;
  if (allJobs) {
    path += `,GITHUB_RUN_ID:${run_id},GITHUB_RUN_ATTEMPT:${run_attempt}`;
  } else {
    path += `,GITHUB_INVOCATION_ID:${invocation_id}`;
  }
  core.info(`api query: ${path}`);
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
        var heading = '';
        if (allJobs) {
          heading = 'nixbuild.net workflow summary';
        } else {
          heading = 'nixbuild.net summary';
        }
        core.summary
          .addHeading(heading)
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
}

const summaryFor = core.getInput('generate-summary-for').toLowerCase();

if (summaryFor === 'job' || summaryFor === 'workflow') {
  var token = '';
  try {
    token = JSON.parse(child_process.execSync(
      'ssh eu.nixbuild.net api tokens create --ttl-seconds 60',
      {encoding: 'utf-8'}
    )).token;
  } catch (error) {
    core.warning('Failed fetching auth token for nixbuild.net, skipping summary generation.');
  }
  if (token) {
    generateSummary(token, summaryFor === 'workflow');
  }
}
