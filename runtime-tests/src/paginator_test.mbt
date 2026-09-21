///|
async test "Paginator starts with None follows empty pages and stays finished" {
  bounded(() => {
    let cursors : Array[String?] = []
    let paginator = @runtime.Paginator::new(cursor => {
      cursors.push(cursor)
      match cursor {
        None => @runtime.Page::{ items: [], next: Some("second"), }
        Some("second") => @runtime.Page::{ items: [1, 2], next: None, }
        _ => raise @runtime.Config("unexpected cursor")
      }
    })
    assert_eq(paginator.next_page(), Some([]))
    assert_eq(paginator.next_page(), Some([1, 2]))
    assert_eq(paginator.next_page(), None)
    assert_eq(paginator.next_page(), None)
    assert_eq(cursors, [None, Some("second")])
  })
}

///|
async test "Paginator each visits every item and collect truncates a page" {
  bounded(() => {
    let each_paginator = @runtime.Paginator::new(cursor => {
      match cursor {
        None => @runtime.Page::{ items: [1, 2], next: Some("next"), }
        Some("next") => @runtime.Page::{ items: [3], next: None, }
        _ => raise @runtime.Config("unexpected cursor")
      }
    })
    let seen = []
    each_paginator.each(item => seen.push(item))
    assert_eq(seen, [1, 2, 3])

    let fetched : Array[String?] = []
    let collect_paginator = @runtime.Paginator::new(cursor => {
      fetched.push(cursor)
      match cursor {
        None => @runtime.Page::{ items: [1, 2, 3], next: Some("next"), }
        Some("next") => @runtime.Page::{ items: [4], next: None, }
        _ => raise @runtime.Config("unexpected cursor")
      }
    })
    assert_eq(collect_paginator.collect(max=2), [1, 2])
    assert_eq(fetched, [None])
    assert_eq(collect_paginator.next_page(), Some([4]))
    assert_eq(collect_paginator.next_page(), None)
    let zero = @runtime.Paginator::new(_ => @runtime.Page::{
      items: [1],
      next: None,
    })
    assert_eq(zero.collect(max=0), [])
  })
}

///|
async test "Paginator failed fetch retries the same cursor" {
  bounded(() => {
    let cursors : Array[String?] = []
    let paginator = @runtime.Paginator::new(cursor => {
      cursors.push(cursor)
      if cursors.length() == 1 {
        raise @runtime.Config("temporary")
      }
      @runtime.Page::{ items: [7], next: None, }
    })
    try paginator.next_page() catch {
      @runtime.Config("temporary") => ()
      _ => fail("expected fetch error")
    } noraise {
      _ => fail("expected fetch error")
    }
    assert_eq(paginator.next_page(), Some([7]))
    assert_eq(cursors, [None, None])
  })
}
