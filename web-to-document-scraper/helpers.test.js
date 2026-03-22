const {find_first_wanted_parent} = require('./helpers')
test('find first wanted parent', () => {
    let test_node1 = {
    }
    let test_node2 = {
        parent:test_node1,
        unwanted:true
    }
    let test_node3 = {
        parent:test_node2
    }

    let result = find_first_wanted_parent(test_node3.parent)

    expect(result).toBe(test_node1);
});