const core = require('@actions/core');
const exec = require('@actions/exec');
const github = require('@actions/github');

async function run() {
  try {
    const inputs = {};
    for (const key in process.env) {
      if (process.env.hasOwnProperty(key)) {
        if (key.startsWith('INPUT_')) {
          inputs[key.substr(6)] = process.env[key];
        }
      }
    }
    core.exportVariable('NIXBUILD_SSH_KEY', core.getInput('nixbuild_ssh_key'));
    await exec.exec('./nixbuild-action.sh', [JSON.stringify(inputs)]);
  } catch (error) {
    core.setFailed(error.message);
  }
}

run();
