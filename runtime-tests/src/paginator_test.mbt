///|
async test "Paginator starts with None follows the cursor and stays finished" {
  bounded(() => {
    let cursors : Array[String?] = []
    let paginator = @runtime.Paginator::with_cursor(cursor => {
      cursors.push(cursor)
      match cursor {
        None => @runtime.Page::{ items: [0], next: Some("second"), }
        Some("second") => @runtime.Page::{ items: [1, 2], next: None, }
        _ => raise @runtime.Config("unexpected cursor")
      }
    })
    assert_eq(paginator.next_page(), Some([0]))
    assert_eq(paginator.next_page(), Some([1, 2]))
    assert_eq(paginator.next_page(), None)
    assert_eq(paginator.next_page(), None)
    assert_eq(cursors, [None, Some("second")])
  })
}

///|
async test "Paginator ends at an empty page even when a cursor follows" {
  bounded(() => {
    let cursors : Array[String?] = []
    let paginator : @runtime.Paginator[Int, @runtime.SdkError] = @runtime.Paginator::with_cursor(cursor => {
        cursors.push(cursor)
        match cursor {
          None => @runtime.Page::{ items: [], next: Some("second"), }
          _ => raise @runtime.Config("unexpected cursor")
        }
      },
    )
    assert_eq(paginator.next_page(), None)
    assert_eq(paginator.next_page(), None)
    assert_eq(cursors, [None])
  })
}

///|
async test "Paginator each visits every item and collect keeps the unused rest" {
  bounded(() => {
    let each_paginator = @runtime.Paginator::with_cursor(cursor => {
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
    let collect_paginator = @runtime.Paginator::with_cursor(cursor => {
      fetched.push(cursor)
      match cursor {
        None => @runtime.Page::{ items: [1, 2, 3], next: Some("next"), }
        Some("next") => @runtime.Page::{ items: [4], next: None, }
        _ => raise @runtime.Config("unexpected cursor")
      }
    })
    assert_eq(collect_paginator.collect(max=2), [1, 2])
    assert_eq(fetched, [None])
    // The unused rest of the page comes back before the next fetch.
    assert_eq(collect_paginator.next_page(), Some([3]))
    assert_eq(fetched, [None])
    assert_eq(collect_paginator.next_page(), Some([4]))
    assert_eq(collect_paginator.next_page(), None)
    let zero : @runtime.Paginator[Int, @runtime.SdkError] = @runtime.Paginator::with_cursor(_ => @runtime.Page::{
        items: [1],
        next: None,
      },
    )
    assert_eq(zero.collect(max=0), [])
  })
}

///|
async test "Paginator failed fetch retries the same cursor" {
  bounded(() => {
    let cursors : Array[String?] = []
    let paginator = @runtime.Paginator::with_cursor(cursor => {
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

///|
async test "Paginator::new lets the fetch own any cursor and stops at None" {
  bounded(() => {
    let calls = Ref(0)
    let paginator : @runtime.Paginator[Int, @runtime.SdkError] = @runtime.Paginator::new(() => {
        calls.val += 1
        match calls.val {
          1 => Some([1, 2])
          2 => Some([3])
          _ => None
        }
      },
    )
    assert_eq(paginator.collect(max=10), [1, 2, 3])
    assert_eq(calls.val, 3)
    assert_eq(paginator.next_page(), None)
    assert_eq(calls.val, 3)
  })
}
