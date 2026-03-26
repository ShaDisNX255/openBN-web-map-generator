const express = require('express')

const generate = require('./generate')
const { asyncSleep } = require('./helpers')
const { unlink } = require('fs/promises')
const { resolve } = require('path')
const process = require('process')
const { fork, execFileSync } = require('child_process');
const path = require('path');

const app = express()
let generateQueue = Promise.resolve();
//For parsing json bodies
app.use(express.json())
//Serve home page
app.use(express.static('home-page'))

const web_server_port = parseInt(process.argv[2]) || 4000
const net_square_url = `http://localhost:${web_server_port}`//`http://localhost:${web_server_port}`
const default_area_path = `areas/default.tmx`

function pidExists(pid) {
  if (!pid) return false;
  try {
    process.kill(pid, 0);
    return true;
  } catch (_) {
    return false;
  }
}

function killPidTreeByPid(pid, signal = 'SIGTERM') {
  if (!pid) return;

  const pkillSignal = signal === 'SIGKILL' ? '-KILL' : '-TERM';

  // Kill detached process group, if there is one.
  try {
    process.kill(-pid, signal);
  } catch (_) {}

  // Kill direct descendants by parent pid.
  try {
    execFileSync('pkill', [pkillSignal, '-P', String(pid)], { stdio: 'ignore' });
  } catch (_) {}

  // Kill the pid itself as fallback.
  try {
    process.kill(pid, signal);
  } catch (_) {}
}

function killChildTree(child, signal = 'SIGTERM') {
  killPidTreeByPid(child?.pid, signal);
}

function waitForProcessGone(pid, timeoutMs = 3000) {
  return new Promise((resolve) => {
    const startedAt = Date.now();

    const poll = () => {
      if (!pidExists(pid)) {
        resolve(true);
        return;
      }

      if (Date.now() - startedAt >= timeoutMs) {
        resolve(false);
        return;
      }

      const t = setTimeout(poll, 200);
      if (typeof t.unref === 'function') {
        t.unref();
      }
    };

    poll();
  });
}

function runGenerateInChild(link, timeoutMs, isHomePage = false) {
  return new Promise((resolve, reject) => {
    const child = fork(
      path.resolve(__dirname, 'run_generate_job.js'),
      [link, String(isHomePage)],
      {
        stdio: ['ignore', 'pipe', 'pipe', 'ipc'],
        detached: process.platform !== 'win32'
      }
    );

    let settled = false;
    let timingOut = false;

    const finish = (fn, value) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      fn(value);
    };

    child.stdout?.on('data', (chunk) => {
      process.stdout.write(`[job ${child.pid}] ${chunk}`);
    });

    child.stderr?.on('data', (chunk) => {
      process.stderr.write(`[job ${child.pid}] ${chunk}`);
    });

    child.on('message', (msg) => {
      if (msg?.ok) {
        finish(resolve, msg.result);
      } else {
        finish(reject, new Error(msg?.error || 'Unknown child job error'));
      }
    });

    child.on('error', (err) => {
      finish(reject, err);
    });

    child.on('exit', (code, signal) => {
      // If we're already in timeout cleanup, let the timeout path finish.
      if (!settled && !timingOut) {
        finish(
          reject,
          new Error(`Generate worker exited before replying (code=${code}, signal=${signal})`)
        );
      }
    });

    const timer = setTimeout(async () => {
      if (settled) return;

      timingOut = true;

      // First ask the worker to stop cleanly.
      killChildTree(child, 'SIGTERM');
      let gone = await waitForProcessGone(child.pid, 2000);

      // If it is still around, hard kill the whole tree.
      if (!gone) {
        killChildTree(child, 'SIGKILL');
        gone = await waitForProcessGone(child.pid, 3000);
      }

      finish(reject, new Error(`Generation timed out after ${timeoutMs}ms`));
    }, timeoutMs);

    if (typeof timer.unref === 'function') {
      timer.unref();
    }
  });
}

//Generate maps on demand
app.post('/', async function (req, res) {
    console.log(req.body)
    let response
    res.status(200)
    if (req?.body?.link) {
        if (req?.body?.link == net_square_url) {
            response = { status: 'ok', area_id: 'default', area_path: 'areas/default.tmx', fresh: false, assets: [] }
        } else {
            try {
const link = req.body.link;

const job = generateQueue.then(() =>
  runGenerateInChild(link, 60000, false)
);

// keep the queue alive even if this job fails
generateQueue = job.catch(() => {});

let { area_id, area_path, assets, fresh } = await job;
response = { status: 'ok', area_id, area_path, fresh, assets };
            } catch (e) {
                console.error(e)
                response = { status: 'error' }
            }
        }
    } else {
        response = { status: 'error' }
    }
    res.send(JSON.stringify(response))
})

app.listen(web_server_port, "127.0.0.1")
console.log(`generation server listening on ${web_server_port}`)

async function test() {
    await asyncSleep(1000)
    try {
        await unlink(resolve('onb-server/' + default_area_path))
    } catch (e) {
        console.log('cant unlink ', resolve('onb-server/' + default_area_path))
    }
    await runGenerateInChild(net_square_url, 60000, true)
}

test()
