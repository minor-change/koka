import std/core

type tree<a> { Node(data : a, children : list<tree<a>>) }

// why does koka require a div effect here?
fun show(Node(a : int, children) : tree<int>) : div string {
    // why do I need std/core/show to be fully qualified here?
    "Tree(" ++ std/core/show(a) ++ ", [" ++ children.map(show).join(", ") ++ "])"
}

fun mapT(Node(a, children) : tree<a>, f : a -> b) : _ tree<b> {
    // this call to map gets specialized and mapT gets specialized in main, however the call to map in the 
    // specialized version of mapT is not specialized
    Node(f(a), std/core/map(children, fn(tree) { tree.mapT(f) }))
}

fun main() {
    val tree = Node(1, [Node(2, []), Node(3, [])])
    tree.mapT(inc).show.println
}