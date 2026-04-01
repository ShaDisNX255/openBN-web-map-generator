const path = require('path')
const sanitize = require('sanitize-filename')
const fs = require('fs')

const { NetAreaGenerator } = require('./new-map-generator/NetAreaGenerator.js')
const TiledTMXExporter = require('./map-exporter/TiledTMXExporter.js')
const { generateNetAreaAssets } = require('./map-exporter/generate_assets.js')
const scrape = require('./scrape_and_convert.js')
const { replaceBackslashes, RNG} = require('./helpers.js')
const {generateBackgroundForWebsite} = require('./background-generator/main.js')
const {generate_color_scheme_from_image} = require('./map-exporter/color_scheme_generator.js')
const {create_warp_active_png} = require('./map-exporter/generate_warp_tile.js')
const crypto = require('crypto')
const { loadImage } = require('canvas')
const url = require('url')
const songs = [
    'boundless-network.ogg',
    'digital-strider.ogg',
    'global-network.ogg',
    'internet-world.ogg',
    'life-in-the-network.ogg',
    'network-is-spreading.ogg',
    'network-space.ogg',
]

const COMMON_SECOND_LEVEL_TLDS = new Set(['ac', 'co', 'com', 'edu', 'gov', 'net', 'org'])

const TAG_DOMAIN_LABEL_OVERRIDES = {
    capcom: 'Capcom',
    github: 'GitHub',
    microsoft: 'Microsoft',
    nintendo: 'Nintendo',
    reddit: 'Reddit',
    wikipedia: 'Wikipedia',
    xbox: 'Xbox',
    youtube: 'YouTube',
}

function getTagRootDomain(hostname = '') {
    const parts = String(hostname || '').toLowerCase().split('.').filter(Boolean)
    if (parts.length <= 2) {
        return parts.join('.')
    }

    const tld = parts[parts.length - 1]
    const sld = parts[parts.length - 2]

    if (tld.length === 2 && COMMON_SECOND_LEVEL_TLDS.has(sld) && parts.length >= 3) {
        return parts.slice(-3).join('.')
    }

    return parts.slice(-2).join('.')
}

function toTitleWords(value = '') {
    return String(value)
        .replace(/[-_]+/g, ' ')
        .replace(/\b\w/g, (match) => match.toUpperCase())
}

function getTagDomainLabel(hostname = '') {
    const rootDomain = getTagRootDomain(hostname)
    const base = rootDomain.split('.')[0] || String(hostname || '')
    return TAG_DOMAIN_LABEL_OVERRIDES[base] || toTitleWords(base)
}

function collectAllNodesUpToDepth(node, maxDepth, depth = 0, out = []) {
    if (!node) return out
    if (depth > maxDepth) return out

    out.push(node)

    const children = node?.features?.children || []
    for (const child of children) {
        collectAllNodesUpToDepth(child, maxDepth, depth + 1, out)
    }

    return out
}

function placePageTagOnRandomNode(rootNode, random, maxDepth = 4) {
    const allNodes = collectAllNodesUpToDepth(rootNode, maxDepth, 0, [])
    if (allNodes.length === 0) return

    // Prefer anything except the root/entry node when possible
    const candidates = allNodes.length > 1 ? allNodes.slice(1) : allNodes
    const chosen = candidates[random.Integer(0, candidates.length - 1)]

    chosen.features = chosen.features || {}
    chosen.features.page_tags = chosen.features.page_tags || []
    chosen.features.page_tags.push({})
}

async function generate(site_url, isHomePage = false) {
    //URL of website to scrape
    console.log('generating',site_url,'...')

    try {
        let normalized_url = new URL(site_url)
        normalized_url.hash = ''
        site_url = normalized_url.toString()
    } catch (e) {
        // leave site_url alone if URL parsing fails
    }

    let hashed_url = crypto.createHash('sha256').update(site_url, 'utf8').digest('hex')
    let web_address = url.parse(site_url)
    let hostname = web_address.hostname
    let web_path_name = web_address.pathname
    let hashed_hostname = crypto.createHash('sha256').update(hostname, 'utf8').digest('hex')

    if (isHomePage) {
        hashed_url = 'default'
        hostname = 'Net_Square'
    }

    //Relative paths for server
    let path_onb_server = path.join('.', 'onb-server')
    let path_domain_assets = path.join(path_onb_server,'assets', 'domain', hostname)
    fs.mkdirSync(path_domain_assets, { recursive: true })

    //Paths for final outputs
    let path_generated_map = path.join(path_onb_server, 'areas', `${hashed_url}.tmx`)
    let path_generated_tiles = path.join(path_onb_server, 'assets', 'generated')
    let path_active_warp_image = path.join(path_domain_assets,'warp_active.png')
    let path_music = path.join('assets', 'shared', 'music')
    let relative_server_music_path = path_music.substring(path_music.indexOf('/') + 1)
    let relative_server_map_path = replaceBackslashes(path_generated_map)
    relative_server_map_path = relative_server_map_path.substring(relative_server_map_path.indexOf('/') + 1)

    //Check if map already exists
    let map_already_exists = fs.existsSync(path_generated_map)
    if (map_already_exists) {
        let result = {
            area_path: relative_server_map_path,
            area_id: hashed_url,
            fresh: false,
        }
        return result
    }

    //Properties which will be included in the map.tmx
    let server_domain_asset_path = replaceBackslashes(path_domain_assets).replace('onb-server/','')
    let site_properties = {
        Name: hostname,
        URL: site_url,
        'Tag Domain': getTagRootDomain(hostname),
        'Tag Domain Label': getTagDomainLabel(hostname),
        'Background Animation': `/server/${server_domain_asset_path}/background.animation`,
        'Background Texture': `/server/${server_domain_asset_path}/background.png`,
    }

    let random = new RNG(parseInt(hashed_hostname, 16))
    site_properties['Song'] = '/server/assets/shared/wwwservertheme.ogg'

    let netAreaGenerator = new NetAreaGenerator()

    const host = hostname || ''
    const domainDepthRules = [
        { pattern: /(^|\.)wikipedia\.org$/i, depth: 3, label: 'wikipedia' },
        { pattern: /(^|\.)google\.com$/i,    depth: 3, label: 'google' },
        { pattern: /(^|\.)reddit\.com$/i,    depth: 5, label: 'reddit' },
        { pattern: /(^|\.)amogus\.org$/i,    depth: 5, label: 'amogus' },
    ]

    for (const rule of domainDepthRules) {
        if (rule.pattern.test(host)) {
            netAreaGenerator.maximumNodeDepth = rule.depth
            console.log(`using ${rule.label} maximumNodeDepth=${netAreaGenerator.maximumNodeDepth}`)
            break
        }
    }

    let scraped_website = await scrape(site_url)
    console.log('scraped site',scraped_website)

    let color_scheme = random.color_scheme(10)
    let favicon

    if (!isHomePage) {
        console.log(`generating background animation`)
        try{
            let favicon_path = await generateBackgroundForWebsite(site_url, 'background', path_domain_assets)
            let based_color_scheme = await generate_color_scheme_from_image(favicon_path)
            if(based_color_scheme){
                color_scheme = based_color_scheme
            }
            favicon = await loadImage(favicon_path)
        }catch(e){
            console.log('Favicon not found...',e)
            site_properties['Background'] = 'misc'
        }
    }else{
        site_properties['Background'] = 'misc'
    }
    //console.log('FINAL COLOR SCHEME',color_scheme)

    //create the active warp tile sprite that will link to this website
    let glow_color = 'white'
    create_warp_active_png(favicon,glow_color, path_active_warp_image)

    console.log(`loading scraped data`)
    LetChildrenKnowAboutTheirParents(scraped_website)

    if (!isHomePage) {
        placePageTagOnRandomNode(scraped_website, random, 4)
    }

    console.log(`generating map...`)
    await netAreaGenerator.generateNetArea(scraped_website, isHomePage)

    console.log(`generating assets for map and remapping tiles`)
    let generated_tiles = await generateNetAreaAssets(netAreaGenerator, path_generated_tiles,hostname,color_scheme)

    console.log('exporting map TMX...')
    let mapExporter = new TiledTMXExporter()
    let tilesets = await mapExporter.ExportTMX(netAreaGenerator, site_properties,path_generated_map)

    console.log(`saved generated map as ${path_generated_map}`)

    let result = {
        area_path: relative_server_map_path,
        area_id: hashed_url,
        assets: tilesets,
        fresh: true,
    }
    return result
}

function LetChildrenKnowAboutTheirParents(node) {
    let children = node?.features?.children
    if (children) {
        for (let child of node?.features?.children) {
            child.parent = node
            LetChildrenKnowAboutTheirParents(child)
        }
    }
}

module.exports = generate
