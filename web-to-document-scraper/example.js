const scraper = require('./scraper.js')
const path = require('path')
const fs = require('fs')
const {cull_unwanted_nodes} = require('./helpers')

const minimum_importance = 1
const tag_blacklist = ["SCRIPT","STYLE"]

async function main(){
    let result = await scraper()
    fs.writeFile(path.resolve(__dirname,"output.json"), JSON.stringify(result, null, 1),()=>{
        console.log('saved to file')
    })
    result = cull_unwanted_nodes(result,tag_blacklist,minimum_importance)
    fs.writeFile(path.resolve(__dirname,"culled.json"), JSON.stringify(result, null, 1),()=>{
        console.log('saved to file')
    })
}
main()

