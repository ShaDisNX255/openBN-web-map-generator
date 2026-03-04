function cull_unwanted_nodes(document,tag_blacklist,minimum_importance,minimum_children){
    //iterate over document and mark all wanted nodes
    let queue = [document]
    while(queue.length > 0 ){
        let node = queue.shift()
        for(let child of node.children){
            child.parent = node
            queue.push(child)
        }
        //if node has a parent, we could remove it if we want
        if(tag_blacklist.includes(node.tag)){
            continue
        }
        if(node.importance < minimum_importance && node.children.length < minimum_children){
            continue
        }
        node.wanted = true
    }

    //iterate over document and delete all unwanted nodes
    queue.push(document)
    while(queue.length > 0 ){
        let node = queue.shift()
        for(let child of node.children){
            queue.push(child)
        }
        if(!node.wanted == true && node.parent){
            node.parent.children.splice(node.parent.children.indexOf(node),1)
        }
        if(node.parent && node.wanted && node.parent.wanted != true){
            //remove node from current parent
            node.parent.children.splice(node.parent.children.indexOf(node),1)
            let new_parent = find_first_wanted_parent(node.parent)
            //add node to new parent
            new_parent.children.push(node)
            node.parent = new_parent
        }
    }

    //remove metadata added during processing of document
    queue.push(document)
    while(queue.length > 0 ){
        let node = queue.shift()
        for(let child of node.children){
            queue.push(child)
        }
        if(node.wanted){
            delete node.wanted
        }
        if(node.importance){
            delete node.importance
        }
    }
    return document
}

function find_first_wanted_parent(parent){
    let parent_layers = 0
    while(parent.wanted != true && parent.parent){
        parent = parent.parent
        parent_layers++
    }
    return parent
}

module.exports = {find_first_wanted_parent,cull_unwanted_nodes}