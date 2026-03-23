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
        //delete conditions
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
        if(node["text"]){
            feature["text"] = node.text
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
        if(node["text"]){
            feature["text"] = node.text
        }
        //delete conditions
        if(feature["text"].length < minimum_text_length || feature["text"].length > maximum_text_length){
            feature.should_be_deleted = true
        }
        if(/<\/?[a-z][\s\S]*>/i.test(feature["text"])){
            feature.should_be_deleted = true
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
    //save converted document
    //await writeFile(outputPath, JSON.stringify(converted_document, null, 1),{ overwrite: true })
    return converted_document
}

module.exports = scrape
