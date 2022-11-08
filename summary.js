const core = require('@actions/core');
const github = require('@actions/github');
const child_process = require('child_process');
const https = require('https');
const fs = require('fs');
const path = require('path');

// https://stackoverflow.com/a/18650828
function formatBytes(bytes, decimals = 0) {
  if (!+bytes) return '0 KB'
  const k = 1024
  const dm = decimals < 0 ? 0 : decimals
  const sizes = ['Bytes', 'KB', 'MB', 'GB', 'TB', 'PB', 'EB', 'ZB', 'YB']
  const i = Math.floor(Math.log(bytes) / Math.log(k))
  return `${parseFloat((bytes / Math.pow(k, i)).toFixed(dm))} ${sizes[i]}`
}

function toHHMMSS(sec_num) {
  var hours   = Math.floor(sec_num / 3600);
  var minutes = Math.floor((sec_num - (hours * 3600)) / 60);
  const seconds = sec_num - (hours * 3600) - (minutes * 60);
  if (hours <= 0 && minutes <= 0) {
    return seconds.toFixed(2)+' s';
  } else {
    var secStr = seconds.toFixed(0);
    if (seconds < 10) { secStr = "0"+secStr; }
    if (minutes < 10) { minutes = "0"+minutes; }
    if (hours <= 0) {
      return minutes+':'+secStr;
    } else {
      if (hours < 10) { hours = "0"+hours; }
      return hours+':'+minutes+':'+secStr;
    }
  }
}

// https://stackoverflow.com/a/15270931/410926
function basename(p) {
  return p.split(/[\\/]/).pop();
}

function statusToColumn(b) {
  var emoji = '&#x2714;'
  switch (b.status) {
    case 'build_failed':
    case 'cancelled':
    case 'timeout':
    case 'max_memory_exceeded':
    case 'client_disconnect':
    case 'client_error':
      emoji = '&#x274C;';
      break;
    case 'internal_error':
    case 'out_of_memory':
      emoji = '&#x1F3F4;';
      break;
    default:
  }
  return `<span title="${b.status}${b.status_message ? `: ${b.status_message}` : ''}">${emoji}</span>`;
}

function derivationToColumn(b) {
  const drvName = path.basename(b.derivation_path, '.drv').substring(33);
  var outputs = '';
  for (const o of b.outputs) {
    outputs = `${outputs}<br/>- ${o.name}: ${o.path} (${formatBytes(o.nar_size_bytes)})`
  }
  return `<details style="margin:0"><summary>${drvName}</summary><pre>build id: ${b.build_id.toString()}<br/>deriver: ${b.derivation_path}<br/>outputs:${outputs}</pre></details>`;
}

function generateSummary(token, allJobs) {
  const workflow = process.env.GITHUB_WORKFLOW;
  const repository = process.env.GITHUB_REPOSITORY;
  const run_id = process.env.GITHUB_RUN_ID;
  const run_attempt = process.env.GITHUB_RUN_ATTEMPT;
  const job = process.env.GITHUB_JOB;
  const invocation_id = fs.readFileSync(path.resolve(process.env.HOME, '__nixbuildnet_invocation_id'));
  const queryParams = allJobs ?
    `tags=GITHUB_REPOSITORY:${repository},GITHUB_RUN_ID:${run_id},GITHUB_RUN_ATTEMPT:${run_attempt}` :
    `tags=GITHUB_REPOSITORY:${repository},GITHUB_INVOCATION_ID:${invocation_id}`;
  const summaryOpts = {
    host: 'api.nixbuild.net',
    path: '/builds/summary?' + queryParams,
    method: 'GET',
    headers: {'Authorization': 'Bearer ' + token}
  };
  const summaryReq = https.request(summaryOpts, function (summaryRes) {
    var summaryBody = '';
    summaryRes.on('data', function (chunk) {
      summaryBody += chunk;
    });
    summaryRes.on('end', function () {
      if (summaryRes.statusCode != 200) {
        core.warning(`nixbuild.net API returned: ${summaryBody}`);
      } else {
        const s = JSON.parse(summaryBody);
        if (s.build_count > 0) {
          const buildsOpts = { ...summaryOpts, path: '/builds?' + queryParams };
          const buildsReq = https.request(buildsOpts, function (buildsRes) {
            var buildsBody = '';
            buildsRes.on('data', function (chunk) {
              buildsBody += chunk;
            });
            buildsRes.on('end', function () {
              if (buildsRes.statusCode != 200) {
                core.warning(`nixbuild.net API returned: ${buildsBody}`);
              } else {
                writeSummary(allJobs, s, JSON.parse(buildsBody));
              }
            });
          });
          buildsReq.on('error', function (err) {
            core.warning(`Error related to HTTPS request: ${err}`);
          });
          buildsReq.end();
        } else {
          writeSummary(allJobs, s, []);
        }
      };
    });
  });
  summaryReq.on('error', function (err) {
    core.warning(`Error related to HTTPS request: ${err}`);
  });
  summaryReq.end();
}

function writeSummary(allJobs, s, builds) {
  const heading = allJobs ?
    '<a href="https://nixbuild.net/">nixbuild.net</a> summary for workflow' :
    '<a href="https://nixbuild.net/">nixbuild.net</a> summary for this job';
  const summary = core.summary
    .addHeading(heading, 3)
    .addTable([
      [ '&#x2714;', 'Successful builds', s.successful_build_count.toString()
      , '&#x23F1;', 'Billable CPU hours', (s.billable_cpu_seconds / 3600.0).toFixed(2)
      ],
      [ '&#x274C;', 'Failed builds', s.failed_build_count.toString(),
      , '&#x1F4E6;', 'Total output size', formatBytes(1024 * s.total_output_nar_size_kilobytes, 2)
      ],
      [ '&#x1F3F4;', 'Restarted builds', s.discarded_build_count.toString()
      , '', '', ''
      ]
    ]);
  if (s.build_count > 0) {
    const headers = [
      ([ '', 'Derivation', 'Duration', 'CPUs', 'Peak memory'
       , 'Peak storage' ]
      ).map(h => ({data: h, header: true}))
    ];
    // Group builds on system
    const systemBuilds = new Map();
    for (const b of builds) {
      var bs = systemBuilds.get(b.system);
      if (bs === undefined) {
        bs = [b];
      } else {
        bs.push(b);
      }
      systemBuilds.set(b.system, bs);
    }
    systemBuilds.forEach((bs, system) => {
      summary.addHeading(`${system} builds (${bs.length.toString()})`, 4);
      summary.addTable(headers.concat(
        bs.sort((x,y) => y.duration_seconds - x.duration_seconds).map(b =>
          [ statusToColumn(b), derivationToColumn(b),
          , toHHMMSS(b.duration_seconds), b.cpu_count.toString()
          , formatBytes(1024 * b.peak_memory_use_kilobytes)
          , formatBytes(1024 * b.peak_storage_use_kilobytes)
          ]
        )
      ));
    })
  };
  summary.write();
}

const summaryFor = core.getInput('generate-summary-for').toLowerCase();

if (summaryFor === 'job' || summaryFor === 'workflow') {
  var token = '';
  try {
    token = JSON.parse(child_process.execSync(
      'ssh eu.nixbuild.net api tokens create --read-only --ttl-seconds 60',
      {encoding: 'utf-8'}
    )).token;
  } catch (error) {
    core.warning('Failed fetching auth token for nixbuild.net, skipping summary generation.');
  }
  if (token) {
    generateSummary(token, summaryFor === 'workflow');
  }
}
