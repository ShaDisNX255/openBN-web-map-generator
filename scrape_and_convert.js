const path = require('path')
const fs = require('fs')

const {writeFile} = require('fs/promises')
const scraper = require('./web-to-document-scraper/scraper.js')
const {cull_unwanted_nodes} = require('./web-to-document-scraper/helpers')
const {fastHash} = require('./helpers')
const {loadImage } = require('canvas')
const {generate_image_board} = require('./map-exporter/generate_image_board.js')
const e = require('express')

const minimum_importance = 1
const maximum_total_importance = 150
const minimum_children = 4
const minimum_text_length = 30
const maximum_text_length = 500
const tag_blacklist = ["SCRIPT","STYLE","SVG"]
const DEFAULT_MAX_LINKS_PER_NODE = 7

const MAX_LINKS_PER_NODE_BY_DOMAIN = [
    { pattern: /(^|\.)wikipedia\.org$/i, maxLinks: 5 },
    { pattern: /(^|\.)google\.com$/i, maxLinks: 5 },
    { pattern: /(^|\.)nintendo\.com$/i, maxLinks: 5 },
    { pattern: /(^|\.)reddit\.com$/i, maxLinks: 13 },
]

const DEFAULT_MAX_IMAGES_PER_NODE = Infinity

const MAX_IMAGES_PER_NODE_BY_DOMAIN = [
    { pattern: /(^|\.)reddit\.com$/i, maxImages: 4 },
]

const REDDIT_UI_TEXT_BLACKLIST = new Set([
    "more replies",
    "more reply",
    "continue this thread",
    "promoted",
    "learn more",
    "collapse navigation",
    "expand navigation",
    "skip to main content",
])

const REDDIT_SUBREDDIT_TAB_PATHS = new Set([
    "new",
    "top",
    "hot",
    "best",
    "rising",
])

var duplicate_links = {}
let current_page_url_for_link_filter = null

//collections and the attributes which are sorted into them
//the order of this collection is also the priority
//if a node has any attribute of the collection, it will return early with that collection type
const collection_attribute_identifiers = {
    images:["src","background-image"],
    links:["href"],
    text:["text"]
}

function create_or_add_to_feature(target_feature,feature_name,feature){
    if(!target_feature.features){
        target_feature.features = {}
    }
    if(!target_feature.features[feature_name]){
        target_feature.features[feature_name] = []
    }
    target_feature.features[feature_name].push(feature)
}

function detect_feature_type(node){
    //detect which collection the node falls into
    for(let collection_name in collection_attribute_identifiers){
        for(let key in node){
            if(key === "parent" || key === "children"){
                continue
            }
            let attributes = collection_attribute_identifiers[collection_name]
            if(attributes.includes(key)){
                return collection_name
            }
        }
    }
    //if the feature does not fit into any other category, it is just a child
    return 'children'
}

function get_url_obj_if_valid(string) {
    try {
        return new URL(string);
    } catch (_) {
        return null;
    }
}

function get_reddit_subreddit_from_url(pageUrl) {
    try {
        const u = new URL(pageUrl)
        const match = u.pathname.match(/^\/r\/([^\/?#]+)/i)
        return match ? match[1].toLowerCase() : null
    } catch (_) {
        return null
    }
}

function is_reddit_ui_text(text) {
    if (typeof text !== "string") return false

    const normalized = text.trim().replace(/\s+/g, " ").toLowerCase()
    if (!normalized) return false

    if (REDDIT_UI_TEXT_BLACKLIST.has(normalized)) {
        return true
    }

    if (normalized.startsWith("more repl")) return true
    if (normalized.startsWith("continue this thread")) return true

    return false
}

function get_max_links_for_url(pageUrl) {
    let host = ''
    try {
        host = new URL(pageUrl).hostname || ''
    } catch (_) {
        return DEFAULT_MAX_LINKS_PER_NODE
    }

    for (const rule of MAX_LINKS_PER_NODE_BY_DOMAIN) {
        if (rule.pattern.test(host)) {
            return rule.maxLinks
        }
    }

    return DEFAULT_MAX_LINKS_PER_NODE
}

function get_max_images_for_url(pageUrl) {
    let host = ''
    try {
        host = new URL(pageUrl).hostname || ''
    } catch (_) {
        return DEFAULT_MAX_IMAGES_PER_NODE
    }

    for (const rule of MAX_IMAGES_PER_NODE_BY_DOMAIN) {
        if (rule.pattern.test(host)) {
            return rule.maxImages
        }
    }

    return DEFAULT_MAX_IMAGES_PER_NODE
}

function score_reddit_link(pageUrl, href) {
    try {
        const page = new URL(pageUrl)
        const target = new URL(href)

        const pageHost = (page.hostname || '').toLowerCase()
        const targetHost = (target.hostname || '').toLowerCase()

        if (!/(^|\.)reddit\.com$/i.test(pageHost) || !/(^|\.)reddit\.com$/i.test(targetHost)) {
            return 0
        }

        const pageSubredditMatch = page.pathname.match(/^\/r\/([^\/?#]+)/i)
        const targetSubredditMatch = target.pathname.match(/^\/r\/([^\/?#]+)/i)

        const pageSubreddit = pageSubredditMatch ? pageSubredditMatch[1].toLowerCase() : null
        const targetSubreddit = targetSubredditMatch ? targetSubredditMatch[1].toLowerCase() : null

        if (!pageSubreddit || !targetSubreddit) {
            return 0
        }

        const sameSubreddit = pageSubreddit === targetSubreddit
        const isCommentPost = new RegExp(`^/r/${pageSubreddit}/comments/`, 'i').test(target.pathname)
        const isSameSubredditOther = new RegExp(`^/r/${pageSubreddit}(/|$)`, 'i').test(target.pathname)

        if (sameSubreddit && isCommentPost) return 100
        if (sameSubreddit && isSameSubredditOther) return 10
        if (/(^|\.)reddit\.com$/i.test(targetHost)) return 1

        return 0
    } catch (_) {
        return 0
    }
}

function score_reddit_image(pageUrl, imageFeature) {
    try {
        const page = new URL(pageUrl)
        const pageHost = (page.hostname || '').toLowerCase()

        if (!/(^|\.)reddit\.com$/i.test(pageHost)) {
            return 0
        }

        const src = String(imageFeature?.src || '').toLowerCase()
        const alt = String(imageFeature?.alt || '').toLowerCase()

        // Strongly prefer actual post/media images
        if (
            src.includes('i.redd.it/') ||
            src.includes('preview.redd.it/') ||
            src.includes('external-preview.redd.it/')
        ) {
            return 100
        }

        // Keep avatars/icons as lower-priority flavor
        if (
            src.includes('styles.redditmedia.com/') ||
            src.includes('www.redditstatic.com/') ||
            src.includes('emoji.redditmedia.com/') ||
            src.includes('avatar')
        ) {
            return 20
        }

        // Some thumbnails may still identify themselves in alt text
        if (alt.startsWith('r/')) {
            return 10
        }

        return 1
    } catch (_) {
        return 0
    }
}

function clamp_links_in_converted_document(rootNode, maxLinksPerNode, pageUrl) {
    if (!rootNode || !Number.isFinite(maxLinksPerNode)) {
        return
    }

    const queue = [rootNode]

    while (queue.length > 0) {
        const node = queue.shift()
        if (!node?.features) {
            continue
        }

        if (Array.isArray(node.features.links)) {
            node.features.links.sort((a, b) => {
                const scoreA = score_reddit_link(pageUrl, a?.href || '')
                const scoreB = score_reddit_link(pageUrl, b?.href || '')
                return scoreB - scoreA
            })

            if (node.features.links.length > maxLinksPerNode) {
                node.features.links = node.features.links.slice(0, maxLinksPerNode)
            }
        }

        if (Array.isArray(node.features.children)) {
            for (const child of node.features.children) {
                if (child) {
                    queue.push(child)
                }
            }
        }
    }
}

function clamp_images_in_converted_document(rootNode, maxImagesPerNode, pageUrl) {
    if (!rootNode || !Number.isFinite(maxImagesPerNode)) {
        return
    }

    const queue = [rootNode]

    while (queue.length > 0) {
        const node = queue.shift()
        if (!node?.features) {
            continue
        }

        if (Array.isArray(node.features.images)) {
            node.features.images.sort((a, b) => {
                const scoreA = score_reddit_image(pageUrl, a || {})
                const scoreB = score_reddit_image(pageUrl, b || {})
                return scoreB - scoreA
            })

            if (node.features.images.length > maxImagesPerNode) {
                node.features.images = node.features.images.slice(0, maxImagesPerNode)
            }
        }

        if (Array.isArray(node.features.children)) {
            for (const child of node.features.children) {
                if (child) {
                    queue.push(child)
                }
            }
        }
    }
}

function get_text_limits_for_url(pageUrl) {
    try {
        const u = new URL(pageUrl)
        const host = (u.hostname || '').toLowerCase()
        const path = u.pathname || ''

        if (/(^|\.)reddit\.com$/i.test(host) && /\/comments\//i.test(path)) {
            return { min: 8, max: 1200 }
        }
    } catch (_) {}

    return { min: minimum_text_length, max: maximum_text_length }
}

async function parse_feature_attributes(feature_collection,node){
    //grab any additional information from the node that we want to keep for the final converted document
    let feature = {}
    //firstly, things that all feature types share
    if(node["tag"]){
        feature["tag"] = node.tag
    }

    if(feature_collection === "images"){
        let src
        if(node["src"]){
            src = node.src
        }
        if(node["alt"]){
            feature["alt"] = node.alt
        }
        if(node["background-image"]){
            let background_image_url = node["background-image"].slice(4, -1).replace(/"/g, "");
            src = background_image_url
        }

        feature["src"] = src

        //delete conditions
        if(!src){
            feature.should_be_deleted = true
            return feature
        }
        if(/ar-gradient/.test(src)){
            feature.should_be_deleted = true
            return feature
        }

        try{
            feature.tsx_path = await generate_image_board(src)
        }catch(e){
            feature.should_be_deleted = true
        }
    }
    if(feature_collection === "links"){
        if(node["href"]){
            feature["href"] = node.href
        }
        if(typeof node?.text === "string" && node.text.trim()){
            feature["text"] = node.text.trim()
        }
        let url = get_url_obj_if_valid(feature["href"])
        if(url){
            //if there is no descripton for the link, default it to the url path if we have one
            if(!feature["text"] && url.pathname){
                feature["text"] = url.pathname
            }
            if(!feature["text"] && url.hostname){
                feature["text"] = url.hostname
            }
        }

        //delete conditions
        if(!url){
            feature.should_be_deleted = true
        }else{
            if(!(url.protocol === "http:" || url.protocol === "https:")){
                feature.should_be_deleted = true
            }
        }

        // Remove same-page anchor links like #bodyContent / #cite_note / etc.
        if(!feature.should_be_deleted && url && current_page_url_for_link_filter){
            try{
                let currentUrl = new URL(current_page_url_for_link_filter)

                let samePage =
                    url.origin === currentUrl.origin &&
                    url.pathname === currentUrl.pathname &&
                    url.search === currentUrl.search

                if(samePage && url.hash){
                    feature.should_be_deleted = true
                }
            }catch(e){
                // ignore filter errors
            }
        }

        // Reddit-specific cleanup: keep same-subreddit links, remove corporate/help/policy chrome
        if(!feature.should_be_deleted && url){
            try{
                const host = (url.hostname || '').toLowerCase()
                const path = url.pathname || ''
                const currentSubreddit = get_reddit_subreddit_from_url(current_page_url_for_link_filter || '')
                const targetSubreddit = get_reddit_subreddit_from_url(url.toString())

                // Kill Reddit-owned help/policy/support stuff completely
                if (
                    /(^|\.)redditinc\.com$/i.test(host) ||
                    /(^|\.)reddithelp\.com$/i.test(host) ||
                    /(^|\.)support\.reddithelp\.com$/i.test(host)
                ) {
                    feature.should_be_deleted = true
                }

                if (!feature.should_be_deleted && /(^|\.)reddit\.com$/i.test(host)) {
                    const isSameSubreddit =
                        currentSubreddit &&
                        targetSubreddit === currentSubreddit &&
                        new RegExp(`^/r/${currentSubreddit}(/|$)`, 'i').test(path)

                    const isRedditChrome =
                        /^\/(policies|settings|login|register|premium|advertising|coins|message|messages|notifications|topics|media|gallery|search|best|explore)/i.test(path)

                    const isUserProfile =
                        /^\/(user|u)\//i.test(path)

                    const isModerationOrBackoffice =
                        /^\/r\/[^/]+\/(about\/modqueue|about\/edited|about\/reports|about\/spam|about\/log|about\/modmail)/i.test(path)

                    const subredditTabMatch = path.match(/^\/r\/[^/]+\/([^/?#]+)\/?$/i)
                    const subredditTabName = subredditTabMatch ? subredditTabMatch[1].toLowerCase() : null
                    const isSubredditTab = subredditTabName && REDDIT_SUBREDDIT_TAB_PATHS.has(subredditTabName)

                    // Remove Reddit UI/button labels even if they are links
                    if (is_reddit_ui_text(feature["text"])) {
                        feature.should_be_deleted = true
                    }

                    // Remove generic Reddit chrome / account / backoffice stuff
                    if (isRedditChrome || isUserProfile || isModerationOrBackoffice || isSubredditTab) {
                        feature.should_be_deleted = true
                    }

                    // If we're on a subreddit page, only keep links that stay inside that same subreddit
                    if (!feature.should_be_deleted && currentSubreddit) {
                        if (!isSameSubreddit) {
                            feature.should_be_deleted = true
                        }
                    }
                }
            }catch(e){
                // ignore reddit filter errors
            }
        }

        // Wikipedia-specific junk link cleanup
        if(!feature.should_be_deleted && url){
            try{
                const host = url.hostname || ''
                const path = url.pathname || ''
                const search = url.search || ''

                if (/(^|\.)wikipedia\.org$/i.test(host)) {
                    const blockedWikiPrefixes = [
                        '/wiki/Wikipedia:',
                        '/wiki/Help:',
                        '/wiki/Special:',
                        '/wiki/Talk:',
                        '/wiki/Portal:',
                        '/wiki/Category:',
                        '/wiki/File:',
                        '/wiki/Template:',
                        '/wiki/Template_talk:',
                        '/wiki/Module:',
                        '/wiki/MediaWiki:'
                    ]

                    if (blockedWikiPrefixes.some(prefix => path.startsWith(prefix))) {
                        feature.should_be_deleted = true
                    }

                    if (path === '/w/index.php') {
                        feature.should_be_deleted = true
                    }

                    if (/action=edit|action=history|veaction=edit|mobileaction=/.test(search)) {
                        feature.should_be_deleted = true
                    }
                }

                if (
                    /(^|\.)wikimedia\.org$/i.test(host) ||
                    /(^|\.)wikimediafoundation\.org$/i.test(host) ||
                    /(^|\.)mediawiki\.org$/i.test(host) ||
                    /(^|\.)developer\.wikimedia\.org$/i.test(host) ||
                    /(^|\.)donate\.wikimedia\.org$/i.test(host)
                ) {
                    feature.should_be_deleted = true
                }
            }catch(e){
                // ignore wikipedia filter errors
            }
        }

        if(feature["text"]){
            let max_length = 40
            if(feature["text"].length > max_length){
                feature["text"] = feature["text"].slice(0, max_length)
            }
        }

        let normalized_href_for_dupes = feature.href
        if(url){
            try{
                let dedupeUrl = new URL(url.toString())
                dedupeUrl.hash = ''
                normalized_href_for_dupes = dedupeUrl.toString()
            }catch(e){}
        }

        let href_hash = `${fastHash(normalized_href_for_dupes)}${normalized_href_for_dupes.length}`
        if(duplicate_links[href_hash]){
            //delete any links that are duplicates
            feature.should_be_deleted = true
        }else{
            //record any links that are not duplicates
            duplicate_links[href_hash] = true
        }
    }
    if(feature_collection === "text"){
        feature["text"] = typeof node?.text === "string" ? node.text.trim() : ""

        const textLimits = get_text_limits_for_url(current_page_url_for_link_filter || '')
        const minTextLength = textLimits.min
        const maxTextLength = textLimits.max

        if(!feature.should_be_deleted && current_page_url_for_link_filter){
            try{
                const currentHost = new URL(current_page_url_for_link_filter).hostname || ''
                if (/(^|\.)reddit\.com$/i.test(currentHost)) {
                    if (is_reddit_ui_text(feature["text"])) {
                        feature.should_be_deleted = true
                    }
                }
            }catch(e){
                // ignore reddit text filter errors
            }
        }

        if(!feature["text"]){
            feature.should_be_deleted = true
        } else {
            if(feature["text"].length < minTextLength || feature["text"].length > maxTextLength){
                feature.should_be_deleted = true
            }
            if(/<\/?[a-z][\s\S]*>/i.test(feature["text"])){
                feature.should_be_deleted = true
            }
        }
    }
    if(feature_collection === "children"){
        if(node["background-color"]){
            feature["background-color"] = node["background-color"]
        }
    }
    return feature
}

async function scrape(url, outputPath) {
    current_page_url_for_link_filter = url
    let document = await scraper(url)
let result = cull_unwanted_nodes(
  document,
  tag_blacklist,
  minimum_importance,
  minimum_children,
  maximum_total_importance // extra arg is fine if helper ignores it
)

// Compat:
// - old helper returned { document, nodes_removed }
// - new helper returns document directly
if (result && typeof result === "object" && "document" in result) {
  while ((result.nodes_removed || 0) > 100) {
    console.log(`nodes removed = ${result.nodes_removed}`)
    result = cull_unwanted_nodes(
      result.document,
      tag_blacklist,
      minimum_importance,
      minimum_children,
      maximum_total_importance
    )
  }
  document = result.document
} else {
  document = result
}

    //expected output
    let example = {
        features:{
            children:[],
            images:[
                {
                    text:"",
                    link:""
                }
            ],
            links:[
                {
                    text:"",
                    link:""
                }
            ]
        }
    }

    let converted_document = {}
    let queue = [document]
    duplicate_links = {}
while (queue.length > 0) {
  const node = queue.shift()
  if (!node || !node.children) continue

  for (const child of node.children) {
    if (child) queue.push(child)
  }
        if(node.parent){
            let feature_collection_name = detect_feature_type(node)
            if(feature_collection_name != 'children'){
                //if this feature is not a child, make sure all its children will be added to this nodes parents
                //rather than to this node (which will be something else like a image feature for example)
                for(let childb of node.children){
                    childb.parent = node.parent
                }
            }
            //now grab all the important information for this feature type from the node
            let feature = await parse_feature_attributes(feature_collection_name,node)
            node.converted_node = feature
            //add the newly generated feature to the parent of this node
            if(!feature.should_be_deleted){
                //only add features to the parent node if they dont suck
                create_or_add_to_feature(node.parent.converted_node,feature_collection_name,feature)
            }
        }else{
            //if this node has no parent, it must be the root feature
            let feature = await parse_feature_attributes("root",node)
            node.converted_node = feature
            converted_document = feature
        }
    }
    current_page_url_for_link_filter = null

    const maxLinksPerNode = get_max_links_for_url(url)
    clamp_links_in_converted_document(converted_document, maxLinksPerNode, url)
    console.log(`clamped links for ${url} to max ${maxLinksPerNode} per node`)

    const maxImagesPerNode = get_max_images_for_url(url)
    clamp_images_in_converted_document(converted_document, maxImagesPerNode, url)
    console.log(`clamped images for ${url} to max ${maxImagesPerNode} per node`)

    //save converted document
    //await writeFile(outputPath, JSON.stringify(converted_document, null, 1),{ overwrite: true })
    return converted_document
}

module.exports = scrape
