redis = require 'redis'
MemoryAdapter = require './adapters/Memory'
Model = require './Model'
Stm = require './Stm'
transaction = require './transaction'

FLUSH_MS = 500

Store = module.exports = (adapterClass) ->
  # TODO: Grab latest version from store and journal
  adapterClass ||= MemoryAdapter
  adapter = new adapterClass
  redisClient = redis.createClient()
  stm = new Stm redisClient
  sockets = null
  @_setSockets = (s) ->
    sockets = s
    sockets.on 'connection', (socket) ->
      socket.on 'txn', (txn) ->
        commit txn, null, (err, txn) ->
          if err && err.code == 'STM_CONFLICT'
            socket.emit 'txnFail', transaction.id txn
      socket.on 'txnsSince', (ver) ->
        txnsSince ver, (txn) ->
          socket.emit 'txn', txn
  
  @_txnsSince = txnsSince = (ver, onTxn) ->
    redisClient.zrangebyscore 'txns', ver, '+inf', 'withscores', (err, vals) ->
      txn = null
      for val, i in vals
        if i % 2
          txn[0] = +val
          onTxn txn
        else
          txn = JSON.parse val
  
  # TODO: This algorithm will need to change when we go multi-process,
  # because we can't count on the version to increase sequentially
  pending = {}
  verToWrite = 1
  setInterval ->
    while txn = pending[verToWrite]
      args = transaction.args txn
      args.push verToWrite, (err) ->
        # TODO: Better adapter error handling and potentially a second callback
        # to the caller of _commit when the adapter operation completes
        throw err if err
      adapter[transaction.method txn].apply adapter, args
      delete pending[verToWrite++]
  , FLUSH_MS
  
  @_commit = commit = (txn, options, callback) ->
    stm.commit txn, options, (err, ver) ->
      txn[0] = ver
      callback err, txn if callback
      return if err
      sockets.emit 'txn', txn if sockets
      pending[ver] = txn
  
  @_nextClientId = nextClientId = (callback) ->
    redisClient.incr 'clientIdCount', (err, value) ->
      throw err if err
      callback value.toString(36)
  
  populateModel = (model, paths, callback) ->
    return callback null, model unless path = paths.pop()
    adapter.get path, (err, value, ver) ->
      callback err if err
      model._adapter.set path, value, ver
      return populateModel model, paths, callback
  @subscribe = (paths..., callback) ->
    # TODO: Attach to an existing model
    # TODO: Support path wildcards, references, and functions
    nextClientId (clientId) ->
      model = new Model clientId
      return callback null, model unless paths
      populateModel model, paths, callback
  
  @unsubscribe = ->
    throw "Unimplemented"
  
  @flush = (callback) ->
    done = false
    cb = (err) ->
      callback err, callback = null if callback && done || err
      done = true
    adapter.flush cb
    redisClient.flushdb cb
  
  return
