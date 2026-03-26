//puppeteer extra with stealth plugin to bypass cloudflare
const puppeteer = require('puppeteer-extra')
const StealthPlugin = require('puppeteer-extra-plugin-stealth')
const { execFileSync } = require('child_process')
puppeteer.use(StealthPlugin())

const goto_page_options = {
  timeout: 20000,
  waitUntil: "domcontentloaded"
}

function pidExists(pid) {
    if (!pid) return false
    try {
        process.kill(pid, 0)
        return true
    } catch (_) {
        return false
    }
}

function killPidTreeByPid(pid, signal = 'SIGKILL') {
    if (!pid) return

    const pkillSignal = signal === 'SIGTERM' ? '-TERM' : '-KILL'

    try {
        process.kill(-pid, signal)
    } catch (_) {}

    try {
        execFileSync('pkill', [pkillSignal, '-P', String(pid)], { stdio: 'ignore' })
    } catch (_) {}

    try {
        process.kill(pid, signal)
    } catch (_) {}
}

async function scraper(url){
    let browser;
    let browserPid = null;
    let emergencyCleanupStarted = false;

    const emergencyBrowserCleanup = () => {
        if (emergencyCleanupStarted) return;
        emergencyCleanupStarted = true;

        if (browserPid && pidExists(browserPid)) {
            killPidTreeByPid(browserPid, 'SIGKILL');
        }
    };

    const onTerminate = () => {
        emergencyBrowserCleanup();
        process.exit(143);
    };

    process.once('SIGTERM', onTerminate);
    process.once('SIGINT', onTerminate);

    try {
        const useProxy = url.includes('reddit.com') || url.includes('x.com') || url.includes('twitter.com') || url.includes('gamejolt.com');
        if (useProxy) console.log(`[scraper] routing ${url} through home proxy`);

        browser = await puppeteer.launch({
          args: [
            "--no-sandbox",
            "--disable-setuid-sandbox",
            "--disable-gpu",
            "--disable-dev-shm-usage",
            ...(useProxy ? ["--proxy-server=socks5://localhost:1080"] : [])
          ],
        });

        browserPid = browser?.process?.()?.pid || null;

        const page = await browser.newPage();
        await page.setJavaScriptEnabled(true);
        await page.setDefaultNavigationTimeout(20000);
        await page.setDefaultTimeout(20000);

        await page.setRequestInterception(true);
        page.on('request', (request) => {
            const type = request.resourceType();
            if (type === 'media' || type === 'font') {
                request.abort();
            } else {
                request.continue();
            }
        });
    //console.log('enabling js')
    await page.setJavaScriptEnabled(true);
    //console.log('going to url')
try {
  await page.goto(url, goto_page_options);
} catch (err) {
  if (err && err.name === "TimeoutError") {
    console.log(`[scraper] timeout loading ${url}, continuing with partial page`);
  } else {
    throw err;
  }
}

try {
  const parsedUrl = new URL(url);
  const host = parsedUrl.hostname || '';
  const path = parsedUrl.pathname || '';

  if (/(^|\.)reddit\.com$/i.test(host)) {
    await page.waitForSelector('shreddit-post, article[data-post-id]', { timeout: 5000 }).catch(() => {});
    await page.waitForTimeout(/\/comments\//i.test(path) ? 3500 : 4500);

    // On subreddit listing pages, scroll a bit to encourage more feed posts to render
    if (/^\/r\/[^/]+\/?$/i.test(path)) {
      await page.evaluate(async () => {
        const sleep = (ms) => new Promise(resolve => setTimeout(resolve, ms));

        window.scrollTo(0, Math.max(document.body.scrollHeight * 0.4, 800));
        await sleep(800);

        window.scrollTo(0, Math.max(document.body.scrollHeight * 0.8, 1600));
        await sleep(1200);

        window.scrollTo(0, 0);
      });

      await page.waitForTimeout(1500);
    }
  }
} catch (_) {}
    //console.log('evaluating script')
    const result = await page.evaluate(() => {
        function record_attributes(node,element,attribute_names,importance){
            for(let attribute_name of attribute_names){
                if(element[attribute_name]){
                    node[attribute_name] = element[attribute_name]
                    node.importance += importance
                }
            }
        }
        function record_attributes_for_tag(node,element,tag_name,attribute_names,importance){
            if(node.tag == tag_name){
                record_attributes(node,element,attribute_names,importance)
            }
        }
        function record_style(node,element,style_name,default_value_to_ignore,importance){
            let style_value = window.getComputedStyle(element,null).getPropertyValue(style_name);  
            if(style_value != default_value_to_ignore){
                node[style_name] = style_value
                node.importance += importance
            }
        }
        function scrape_extra_data(node,element){
            record_attributes(node,element,"id",1)
            record_attributes_for_tag(node,element,"A",["href"],1)
            record_attributes_for_tag(node,element,"IMG",["src","alt"],1)
            record_style(node,element,'background-color','rgba(0, 0, 0, 0)',1)
            //record_style(node,element,'background-image','none',1) often causes generation failure with gradients
        }
        function getTextFromElement(element){
            let text = ""
            if(element.childNodes.length == 0){
                //dont add text of elements with children because it will be duplicated
                if(element?.dataset?.title){
                    text += element.dataset.title
                }
                if(element.textContent){
                    text += element.textContent
                }
                if(element.innerText){
                    text += element.innerText
                }
            }
            for( child_node of element.childNodes){
                if (child_node.nodeType === Node.TEXT_NODE){
                    text += child_node.textContent;
                }
            }
            text = text.replace(/(\r\n|\t|\n|\r)/gm, "")//remove new line characters
            text = text.replace(/\s+/g, " ")//remove consecutive spaces
            return text.trim()//remove leading and trailing spaces
        }
        let queue = []

        let rootElement = document
        try {
            const host = window.location.hostname
            const path = window.location.pathname || ''

            if (/(^|\.)reddit\.com$/i.test(host)) {
                rootElement =
                    document.querySelector('main') ||
                    document.querySelector('shreddit-app') ||
                    document.body ||
                    document
            } else if (/(^|\.)wikipedia\.org$/i.test(host)) {
                rootElement =
                    document.querySelector('#mw-content-text') ||
                    document.querySelector('#bodyContent') ||
                    document.querySelector('main') ||
                    document
            }
        } catch (e) {
            rootElement = document
        }

        let first_node = {element:rootElement,children:[]}
        queue.push(first_node)
        while (queue.length > 0) {
            let node = queue.shift()
            for(let child of node.element.children){
                let child_node = {tag:child.tagName,element:child,children:[],text:getTextFromElement(child),importance:0}
                if(child_node.text == ""){
                    delete child_node.text
                }else{
                    //having text on the node adds importance
                    child_node.importance += 1
                }

                scrape_extra_data(child_node,child)

                node.children.push(child_node)
                queue.push(child_node)
            }
            delete node.element //we dont need it anymore
        }
        return first_node
    });
        return result
    } finally {
        process.removeListener('SIGTERM', onTerminate);
        process.removeListener('SIGINT', onTerminate);

        if (browser) {
            try {
                await browser.close();
            } catch (_) {}
        }

        if (browserPid && pidExists(browserPid)) {
            killPidTreeByPid(browserPid, 'SIGKILL');
        }
    }
}

module.exports = scraper
