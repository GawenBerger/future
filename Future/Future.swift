//
//  Future.swift
//  Future
//
//  Created by Olivier THIERRY on 06/09/15.
//  Copyright (c) 2015 Olivier THIERRY. All rights reserved.
//

import Foundation

let futureQueueConcurrent = dispatch_queue_create(
  "com.future.queue:concurrent",
  DISPATCH_QUEUE_CONCURRENT)

/**
  States a future can go trought

  - `.Pending` : The future is waiting to be resolve or rejected
  - `.Resolve` : The future has been resolved using `future.resolve(_:A)`
  - `.Rejected`: The future has been rejected using `future.reject(_:NSError?)`

  Important: A future can only be resolved/rejected ONCE. If a future tries to
  resolve/reject 2 times, an exception will be raised.
*/
public enum State {
  case Pending, Resolved, Rejected
}

public class Future<A> {
  
  /// The resolved value `A`
  var value: A!
  
  /// The error used when the future was rejected
  var error: NSError?

  /// The current state of the future
  var state: State = .Pending

  /// Optionnal. An identifier assigned to the future. This is useful to debug
  /// multiple, concurrent futures.
  var identifier: String?
  
  /// Fonction chaining to keep track of functions to invoke when
  /// rejecting or resolving a future in FIFO mode.
  ///
  /// Important: When resolved, the future will discard `fail` chain fonctions.
  /// When rejected, the future will discard `then` chain fonctions
  private var chain: (then: [A -> Void], fail: [NSError? -> Void]) = ([], [])

  /**
    Designated static initializer for async futures.
    The method executes the block asynchronously in background queue
    (Future.futureQueueConcurrent)
  
    Parameter: f: The block to execute with the future as parameter.
  
    Returns: The created future object
  */
  public static func incoming(f: Future<A> -> Void) -> Future<A> {
    let future = Future<A>()
    dispatch_async(futureQueueConcurrent) {
      f(future)
    }
    return future
  }
  
  /**
    Create a resolve future directly. Useful when you need to
    return a future of a value that has already been fetched or
    computed
  
    Parameter value: The value to resolve
  
    Returns: The future
  */
  public static func resolve<A>(value: A) -> Future<A> {
    return Future<A>.incoming { $0.resolve(value) }
  }
  
  /**
    Create a reject future directly. Useful when you need to
    return a future of a value that you instatanly know that
    can not be resolved and should be rejected
  
    Parameter error: The error to reject
  
    Returns: The future
  */
  public static func fail<A>(error: NSError?) -> Future<A> {
    return Future<A>.incoming { $0.reject(error) }
  }
}

public extension Future {

  /**
    Add a fonction to fonction `then` chain.
  
    Parameter f: The fonction to execute
  
    Returns: self
  
    Important: `f` is garanteed to be executed on main queue
  */
  public func then(f: A -> Void) -> Future<A> {
    appendThen { value in f(value) }
    return self
  }
  
  /**
    Add a fonction to fonction `then` chain. This fonction returns
    a new type `B`. A new future of type B is created and
    returned as the result of this fonction
  
    Parameter f: The fonction to execute
  
    Returns: the future
  
    Important: `f` is garanteed to be executed on main queue
  */
  public func then<B>(f: A -> B) -> Future<B> {
    let future = Future<B>()
    
    appendThen { value in
      future.resolve(f(value))
    }
    
    appendFail { error in
      future.reject(error)
    }
    
    return future
  }
  
  /**
    Add a fonction to fonction `then` chain. This fonction returns
    a new Future of type `B`.
  
    Parameter f: The fonction to execute
  
    Returns: the future
  
    Important: `f` is garanteed to be executed on main queue
  */
  public func then<B>(f: A -> Future<B>) -> Future<B> {
    let future = Future<B>()
    
    appendThen { value in
      f(value)
        .then(future.resolve)
        .fail(future.reject)
    }
    
    appendFail { error in
      future.reject(error)
    }
    
    return future
  }
  
  /**
    Add a fonction to fonction `fail` chain.
  
    Parameter f: The fonction to execute
  
    Returns: self
  
    Important: `f` is garanteed to be executed on main queue
  */
  public func fail(f: NSError? -> Void) -> Future<A> {
    appendFail { error in f(error) }
    return self
  }
  
  /**
    Append fonction in fonction `then` chain
  
    Important: This fonction locks the future instance
    to do its work. This prevent inconsistent states
    that can pop when multiple threads access the
    same future instance
  */
  private func appendThen(f: A -> Void) {
    // Avoid concurrent access, synchronise threads
    objc_sync_enter(self)
    
    self.chain.then.append(f)
    
    // If future is already resolved, invoke functions chain now
    if state == .Resolved {
      resolveAll()
    }
    
    // Release lock
    objc_sync_exit(self)
  }
  
  /**
    Append fonction in fonction `fail` chain
  
    Important: This fonction locks the future instance
    to do its work. This prevent inconsistent states
    that can pop when multiple threads access the
    same future instance
  */
  private func appendFail(f: NSError? -> Void) {
    // Avoid concurrent access, synchronise threads
    objc_sync_enter(self)
    
    self.chain.fail.append(f)
    
    // If future is already rejected, invoke functions chain now
    if state == .Rejected {
      rejectAll()
    }
    
    // Release lock
    objc_sync_exit(self)
  }
  
}

public extension Future {
  
  /**
    Resolve a future
  
    Parameter value: The value to resolve with

    Important: This fonction locks the future instance
    to do its work. This prevent inconsistent states
    that can pop when multiple threads access the
    same future instance
  */
  public func resolve(value: A) {
    // Avoid concurrent access, synchronise threads
    objc_sync_enter(self)
    
    // Throw if trying to resolve/reject promise that has already
    // been resolved/rejected
    if state != .Pending {
      /// TODO: Handle error properly
      return
//      throw NSError(
//        domain: "com.future",
//        code: 1,
//        userInfo: [
//          NSLocalizedDescriptionKey: "Promise has already been resolved/rejected. identifier: \(self.identifier)"
//        ])
    }

    // Store given value
    self.value = value
    
    // Invoke all success fonctions in fonctions chain
    resolveAll()

    // Assign state as .Resolved
    self.state = .Resolved

    // Release lock
    objc_sync_exit(self)
  }
  
  
  /**
    Reject a future
  
    Parameter error: The error to reject with (optional)
  
    Important: This fonction locks the future instance
    to do its work. This prevent inconsistent states
    that can pop when multiple threads access the
    same future instance
  */
  public func reject(error: NSError? = nil) {
    // Avoid concurrent access, synchronise threads
    objc_sync_enter(self)

    // Throw if trying to resolve/reject promise that has already
    // been resolved/rejected
    if state != .Pending {
      /// TODO: Handle error properly
      return
      
//      throw NSError(
//        domain: NSInternalInconsistencyException,
//        code: 1,
//        userInfo: [
//          NSLocalizedDescriptionKey: "Promise has already been resolved/rejected. identifier: \(self.identifier)"
//        ])
    }
    
    // Store given error
    self.error = error
    
    // Invoke failure functions in fonctions chain
    rejectAll()
    
    // Assign state as .Rejected
    self.state = .Rejected
    
    // Release lock
    objc_sync_exit(self)
  }

  /**
    Invoke all function in `then` function chain
    and empty chain after complete
  */
  private func resolveAll() {
    for f in self.chain.then {
      dispatch_async(dispatch_get_main_queue()) {
        f(self.value)
      }
    }
    
    self.chain.then = []
  }

  /**
    Invoke all function in `fail` function chain
    and empty chain after complete
  */
  private func rejectAll() {
    for f in self.chain.fail {
      dispatch_async(dispatch_get_main_queue()) {
        f(self.error)
      }
    }
    
    self.chain.fail = []
  }
  
}

public extension Future {
  
  /**
    Wait until all futures complete and resolve by mapping the values
    of all the futures
  
    If one future fails, the future will be rejected with the same error
  
    Parameter futures: an array of futures to resolve
  
    Returns: future object
  */
  public static func all<A>(futures: [Future<A>]) -> Future<[A]> {
    return Future<[A]>.incoming { rootFuture in
      guard !futures.isEmpty else {
        return rootFuture.resolve([])
      }
      
      var objects: [A] = []
      for future in futures {
        future.then { object in
          objects.append(object)
          if objects.count == futures.count {
            rootFuture.resolve(objects)
          }
        }.fail(rootFuture.reject)
      }
    }
  }
  
}

public extension Future {

  /**
    Wrap the result of a future into a new Future<Void>
  
    This is useful when a future actually resolves a value
    with a concrete type but the caller of the future do not
    care about this value and expect Void
  
    Example:
  
    ```
    class A: SomeProtocol {
      // Protocol conforming requires this
      var future: Future<Void> {
        return Future<User>.incoming { future
          let user = ...
          future.resolve(user)
        }.then { user
          print("user found \(user)")
        }.wrapped() // Is now a Future<Void>
      }
    }
    ```
  */
  public func wrapped() -> Future<Void> {
    return then { _ -> Future<Void> in Future<Void>.resolve() }
  }

  /**
    Wrap the result of a future into a new Future<C>
  
    This is useful when a future actually resolves a value
    with a concrete type but the caller of the future expect
    another type your value type can be downcasted to.
  
    Example:
  
    ```
    class A: SomeProtocol {
      // Protocol conforming requires this
      var future: Future<AnyObject> {
        return Future<User>.incoming { future
          let user = ...
          future.resolve(user)
        }.then { user
          print("user found \(user)")
        }.wrapped(AnyObject) // Is now a Future<AnyObject>
      }
    }
  ```
  */
  public func wrapped<C>(_: C.Type) -> Future<C> {
    /// TODO: Check error when using as! instead of `unsafeBitCast`
    /// Why do we need `unsafeBitCast` ?
    return then { object -> C in unsafeBitCast(object, C.self) }
  }

}
