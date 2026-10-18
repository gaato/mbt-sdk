///|
priv enum TicketState {
  Waiting
  Granted
  Refused
}

///|
/// One request's claim on a connection slot.
priv struct Ticket {
  origin : String
  mut state : TicketState
  cond : @cond_var.Cond
}

///|
/// Connections in use by an exchange, from its slot wait until its body is
/// read or abandoned, in all and per origin, under optional caps. Parked
/// connections hold no slot. A request that finds no slot waits; slots are
/// granted in arrival order to the waiters they fit, so a waiter whose origin
/// is at its cap does not hold up one for another origin. Waiters leave the
/// queue when they give up, so it holds only the requests waiting right now.
priv struct Slots {
  max_total : Int32?
  max_per_origin : Int32?
  mut in_use : Int32
  per_origin : Map[String, Int32]
  waiting : Array[Ticket]
}

///|
/// Caps below 1 are taken as 1, since a cap of 0 would refuse every request.
fn Slots::new(max_total? : Int32, max_per_origin? : Int32) -> Slots {
  {
    max_total: max_total.map(cap => cap.max(1)),
    max_per_origin: max_per_origin.map(cap => cap.max(1)),
    in_use: 0,
    per_origin: {},
    waiting: [],
  }
}

///|
fn Slots::fits(self : Slots, origin : String) -> Bool {
  let total_ok = match self.max_total {
    Some(cap) => self.in_use < cap
    None => true
  }
  let origin_ok = match self.max_per_origin {
    Some(cap) => self.per_origin.get(origin).unwrap_or(0) < cap
    None => true
  }
  total_ok && origin_ok
}

///|
fn Slots::take(self : Slots, origin : String) -> Unit {
  self.in_use += 1
  self.per_origin[origin] = self.per_origin.get(origin).unwrap_or(0) + 1
}

///|
/// Hands freed slots to the waiters they fit, earliest first.
fn Slots::grant_waiting(self : Slots) -> Unit {
  let mut i = 0
  while i < self.waiting.length() {
    let ticket = self.waiting[i]
    if self.fits(ticket.origin) {
      ignore(self.waiting.remove(i))
      self.take(ticket.origin)
      ticket.state = Granted
      ticket.cond.signal()
    } else {
      i += 1
    }
  }
}

///|
/// A ticket for `origin`: granted at once when a slot is free, otherwise
/// queued behind the requests already waiting. A free slot never has a
/// waiter it fits, since releases hand slots out as they free them.
fn Slots::enqueue(self : Slots, origin : String) -> Ticket {
  let ticket = { origin, state: Waiting, cond: @cond_var.Cond(), }
  if self.fits(origin) {
    self.take(origin)
    ticket.state = Granted
  } else {
    self.waiting.push(ticket)
  }
  ticket
}

///|
/// Frees a slot of `origin` and hands it on.
fn Slots::release(self : Slots, origin : String) -> Unit {
  self.in_use -= 1
  match self.per_origin.get(origin) {
    Some(count) if count > 1 => self.per_origin[origin] = count - 1
    _ => self.per_origin.remove(origin)
  }
  self.grant_waiting()
}

///|
/// Gives up `ticket`: a granted slot is released, a waiting ticket leaves the
/// queue without touching any slot.
fn Slots::abandon(self : Slots, ticket : Ticket) -> Unit {
  match ticket.state {
    Granted => self.release(ticket.origin)
    Waiting => {
      self.waiting.retain(other => !physical_equal(other, ticket))
      ticket.state = Refused
    }
    Refused => ()
  }
}

///|
/// Refuses every waiting ticket, as when the transport closes.
fn Slots::refuse_waiting(self : Slots) -> Unit {
  for ticket in self.waiting {
    ticket.state = Refused
    ticket.cond.signal()
  }
  self.waiting.clear()
}

///|
/// Waits until the ticket is granted; a refused ticket raises
/// `Connect("transport closed")`.
async fn Ticket::wait(self : Ticket) -> Unit raise @http.HttpError {
  while self.state is Waiting {
    self.cond.wait()
  }
  if self.state is Refused {
    raise @http.HttpError::Connect("transport closed")
  }
}

///|
/// Takes a slot for `origin`, waiting for one as the `Pool` phase of `timer`
/// when none is free. On a timeout, a failure or cancellation the request
/// leaves the queue, releasing a slot only if it had been granted one.
async fn Slots::acquire(
  self : Slots,
  origin : String,
  timer : PhaseTimer,
) -> Unit raise @http.HttpError {
  let ticket = self.enqueue(origin)
  errdefer self.abandon(ticket)
  if ticket.state is Waiting {
    timer.run(Pool, () => ticket.wait())
  }
}
