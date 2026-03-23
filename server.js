const express = require('express')

const generate = require('./generate')
const { asyncSleep } = require('./helpers')
const { unlink } = require('fs/promises')
const { resolve } = require('path')
const process = require('process')
const { fork } = require('child_process');
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

function runGenerateInChild(link, timeoutMs, isHomePage = false) {
  return new Promise((resolve, reject) => {
    const child = fork(
      path.resolve(__dirname, 'run_generate_job.js'),
      [link, String(isHomePage)],
      {
        stdio: ['ignore', 'pipe', 'pipe', 'ipc']
      }
    );

    let settled = false;

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
      if (!settled) {
        finish(
          reject,
          new Error(`Generate worker exited before replying (code=${code}, signal=${signal})`)
        );
      }
    });

    const timer = setTimeout(() => {
      if (settled) return;

      child.kill('SIGTERM');

      setTimeout(() => {
        if (!settled) {
          child.kill('SIGKILL');
        }
      }, 5000);

      finish(reject, new Error(`Generation timed out after ${timeoutMs}ms`));
    }, timeoutMs);
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
