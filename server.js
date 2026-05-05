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
const MAX_UNIQUE_PENDING_JOBS = 400;
const JOB_RESULT_TTL_MS = 10 * 60 * 1000;

const jobsByKey = new Map();
const queuedJobKeys = [];
let runningJobKey = null;

function normalizeLink(rawLink) {
  try {
    const u = new URL(rawLink);
    u.hash = '';
    u.hostname = (u.hostname || '').toLowerCase();

    if ((u.protocol === 'http:' && u.port === '80') ||
        (u.protocol === 'https:' && u.port === '443')) {
      u.port = '';
    }

    return u.toString();
  } catch (_) {
    return rawLink;
  }
}

function pendingJobCount() {
  return queuedJobKeys.length + (runningJobKey ? 1 : 0);
}

function getQueuePositionForKey(key) {
  if (runningJobKey === key) {
    return 0;
  }

  const index = queuedJobKeys.indexOf(key);
  return index === -1 ? null : index + 1;
}

function scheduleJobRecordCleanup(key) {
  const record = jobsByKey.get(key);
  if (!record) return;

  if (record.cleanupTimer) {
    clearTimeout(record.cleanupTimer);
  }

  record.cleanupTimer = setTimeout(() => {
    const latest = jobsByKey.get(key);
    if (!latest) return;

    if (latest.status === 'done' || latest.status === 'error') {
      jobsByKey.delete(key);
    }
  }, JOB_RESULT_TTL_MS);

  if (typeof record.cleanupTimer.unref === 'function') {
    record.cleanupTimer.unref();
  }
}

function enqueueJobIfNeeded(rawLink) {
  const key = normalizeLink(rawLink);

  let record = jobsByKey.get(key);
  if (record) {
    return { record, created: false };
  }

  if (pendingJobCount() >= MAX_UNIQUE_PENDING_JOBS) {
    return { queueFull: true, key };
  }

  record = {
    key,
    link: key,
    status: 'queued',
    createdAt: Date.now(),
    updatedAt: Date.now(),
    result: null,
    error: null,
    cleanupTimer: null,
  };

  jobsByKey.set(key, record);
  queuedJobKeys.push(key);

  const job = generateQueue.then(async () => {
    const index = queuedJobKeys.indexOf(key);
    if (index !== -1) {
      queuedJobKeys.splice(index, 1);
    }

    runningJobKey = key;
    record.status = 'running';
    record.updatedAt = Date.now();

    try {
      const result = await runGenerateInChild(record.link, 60000, false);
      record.status = 'done';
      record.result = result;
      record.error = null;
      record.updatedAt = Date.now();
    } catch (err) {
      record.status = 'error';
      record.result = null;
      record.error = err?.message || String(err);
      record.updatedAt = Date.now();
    } finally {
      if (runningJobKey === key) {
        runningJobKey = null;
      }
      scheduleJobRecordCleanup(key);
    }
  });

  record.jobPromise = job;
  generateQueue = job.catch(() => {});

  return { record, created: true };
}
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
    const rawLink = req?.body?.link;
    res.status(200);

    if (!rawLink) {
        return res.json({ status: 'error' });
    }

    const normalizedLink = normalizeLink(rawLink);

    if (normalizedLink === normalizeLink(net_square_url)) {
        return res.json({
            status: 'ok',
            area_id: 'default',
            area_path: 'areas/default.tmx',
            fresh: false,
            assets: []
        });
    }

    try {
        const { record, queueFull, created } = enqueueJobIfNeeded(normalizedLink);

        if (queueFull) {
            return res.json({
                status: 'queue_full',
                queue_size: pendingJobCount(),
                max_queue_size: MAX_UNIQUE_PENDING_JOBS
            });
        }

        if (created && record.jobPromise) {
            try {
                await record.jobPromise;
            } catch (_) {
                // record.status / record.error are already set by the job runner
            }
        }

        if (record.status === 'done') {
            return res.json({
                status: 'ok',
                ...record.result
            });
        }

        if (record.status === 'error') {
            return res.json({
                status: 'error',
                message: record.error || 'Generation failed'
            });
        }

        return res.json({
            status: 'queued',
            link: normalizedLink,
            queue_position: getQueuePositionForKey(record.key),
            queue_size: pendingJobCount()
        });
    } catch (e) {
        console.error(e);
        return res.json({ status: 'error' });
    }
});

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
