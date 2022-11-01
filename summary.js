const core = require('@actions/core');
const github = require('@actions/github');
const child_process = require('child_process');
const https = require('https');

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
  const path = `/builds/summary?tags=GITHUB_REPOSITORY:${repository},GITHUB_RUN_ID:${run_id},GITHUB_RUN_ATTEMPT:${run_attempt}`;
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
