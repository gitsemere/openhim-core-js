# Set app root global
path = require 'path'
global.appRoot = path.join path.resolve(__dirname), '..'

fs = require 'fs'
http = require 'http'
https = require 'https'
net = require 'net'
dgram = require 'dgram'
koaMiddleware = require "./koaMiddleware"
koaApi = require "./koaApi"
tlsAuthentication = require "./middleware/tlsAuthentication"
config = require "./config/config"
config.authentication = config.get('authentication')
config.router = config.get('router')
config.api = config.get('api')
config.rerun = config.get('rerun')
config.tcpAdapter = config.get('tcpAdapter')
config.logger = config.get('logger')
config.alerts = config.get('alerts')
config.polling = config.get('polling')
config.reports = config.get('reports')
config.auditing = config.get('auditing')
uuid = require 'node-uuid'

Q = require "q"
logger = require "winston"
logger.level = config.logger.level
mongoose = require "mongoose"
User = require('./model/users').User
Keystore = require('./model/keystore').Keystore
pem = require 'pem'
Agenda = require 'agenda'
alerts = require './alerts'
reports = require './reports'
polling = require './polling'
tcpAdapter = require './tcpAdapter'
workerAPI = require './api/worker'
auditing = require './auditing'

# Configure mongose to connect to mongo
mongoose.connect config.mongo.url

httpServer = null
httpsServer = null
apiHttpsServer = null
rerunServer = null
tcpHttpReceiver = null
pollingServer = null

auditUDPServer = null

activeHttpConnections = {}
activeHttpsConnections = {}
activeApiConnections = {}
activeRerunConnections = {}
activeTcpConnections = {}
activePollingConnections = {}

trackConnection = (map, socket) ->
  # save active socket
  id = uuid.v4()
  map[id] = socket

  # remove socket once it closes
  socket.on 'close', ->
    map[id] = null
    delete map[id]

  # log any socket errors
  socket.on 'error', (err) ->
    logger.error err

exports.isTcpHttpReceiverRunning = -> tcpHttpReceiver?

rootUser =
  firstname: 'Super'
  surname: 'User'
  email: 'root@openhim.org'
  passwordAlgorithm: 'sha512'
  passwordHash: '943a856bba65aad6c639d5c8d4a11fc8bb7fe9de62ae307aec8cf6ae6c1faab722127964c71db4bdd2ea2cdf60c6e4094dcad54d4522ab2839b65ae98100d0fb'
  passwordSalt: 'd9bcb40e-ae65-478f-962e-5e5e5e7d0a01'
  groups: [ 'admin' ]
  # password = 'openhim-password'

defaultKeystore =
  key: fs.readFileSync "#{appRoot}/resources/certs/default/key.pem"
  cert:
    country: 'ZA'
    state: 'KZN'
    locality: 'Durban'
    organization: 'OpenHIM Default Certificate'
    organizationUnit: 'Default'
    commonName: '*.openhim.org'
    emailAddress: 'openhim-implementers@googlegroups.com'
    validity:
      start: 1423810077000
      end: 3151810077000
    data: fs.readFileSync "#{appRoot}/resources/certs/default/cert.pem"
  ca: []

# Job scheduler
agenda = null

startAgenda = ->
  agenda = new Agenda db: { address: config.mongo.url}
  alerts.setupAgenda agenda if config.alerts.enableAlerts
  reports.setupAgenda agenda if config.reports.enableReports
  polling.setupAgenda agenda, ->
    agenda.start()
    logger.info "Started agenda job scheduler"

stopAgenda = ->
  defer = Q.defer()
  agenda.stop () ->
    defer.resolve()
    logger.info "Stopped agenda job scheduler"
  return defer

startHttpServer = (httpPort, bindAddress, app) ->
  deferred = Q.defer()

  httpServer = http.createServer app.callback()

  # set the socket timeout
  httpServer.setTimeout config.router.timeout, ->
    logger.info "HTTP socket timeout reached"

  httpServer.listen httpPort, bindAddress, ->
    logger.info "HTTP listening on port " + httpPort
    deferred.resolve()

  httpServer.on 'connection', (socket) -> trackConnection activeHttpConnections, socket

  return deferred

startHttpsServer = (httpsPort, bindAddress, app) ->
  deferred = Q.defer()

  mutualTLS = config.authentication.enableMutualTLSAuthentication
  tlsAuthentication.getServerOptions mutualTLS, (err, options) ->
    return done err if err
    httpsServer = https.createServer options, app.callback()

    # set the socket timeout
    httpsServer.setTimeout config.router.timeout, ->
      logger.info "HTTPS socket timeout reached"

    httpsServer.listen httpsPort, bindAddress, ->
      logger.info "HTTPS listening on port " + httpsPort
      deferred.resolve()

    httpsServer.on 'connection', (socket) -> trackConnection activeHttpsConnections, socket

  return deferred

# Ensure that a root user always exists
ensureRootUser = (callback) ->
  User.findOne { email: 'root@openhim.org' }, (err, user) ->
    if !user
      user = new User rootUser
      user.save (err) ->
        if err
          logger.error "Could not save root user: " + err
          return callback err

        logger.info "Root user created."
        callback()
    else
      callback()

# Ensure that a default keystore always exists
ensureKeystore = (callback) ->
  Keystore.findOne {}, (err, keystore) ->
    if not keystore?
      keystore = new Keystore defaultKeystore
      keystore.save (err, keystore) ->
        if err
          logger.error "Could not save keystore: " + err
          return callback err

        logger.info "Default keystore created."
        callback()
    else
      callback()

startApiServer = (apiPort, bindAddress, app) ->
  deferred = Q.defer()

  # mutualTLS not applicable for the API - set false
  mutualTLS = false
  tlsAuthentication.getServerOptions mutualTLS, (err, options) ->
    logger.error "Could not fetch https server options: #{err}" if err

    apiHttpsServer = https.createServer options, app.callback()
    apiHttpsServer.listen apiPort, bindAddress, ->
      logger.info "API HTTPS listening on port " + apiPort
      ensureRootUser -> deferred.resolve()

    apiHttpsServer.on 'connection', (socket) -> trackConnection activeApiConnections, socket

  return deferred

startTCPServersAndHttpReceiver = (tcpHttpReceiverPort, app) ->
  defer = Q.defer()

  tcpHttpReceiver = http.createServer app.callback()
  tcpHttpReceiver.listen tcpHttpReceiverPort, config.tcpAdapter.httpReceiver.host, ->
    logger.info "HTTP receiver for Socket adapter listening on port #{tcpHttpReceiverPort}"
    tcpAdapter.startupServers (err) ->
      logger.error err if err
      defer.resolve()

  tcpHttpReceiver.on 'connection', (socket) -> trackConnection activeTcpConnections, socket

  return defer

startRerunServer = (httpPort, app) ->
  deferredHttp = Q.defer()

  rerunServer = http.createServer app.callback()
  rerunServer.listen httpPort, config.rerun.host, ->
    logger.info "Transaction Rerun HTTP listening on port " + httpPort
    deferredHttp.resolve()

  rerunServer.on 'connection', (socket) -> trackConnection activeRerunConnections, socket

  return deferredHttp

startPollingServer = (pollingPort, app) ->
  defer = Q.defer()

  pollingServer = http.createServer app.callback()
  pollingServer.listen pollingPort, config.polling.host, (err) ->
    logger.error err if err
    logger.info 'Polling port listening on port ' + pollingPort
    defer.resolve()

  pollingServer.on 'connection', (socket) -> trackConnection activePollingConnections, socket

  return defer

startAuditUDPServer = (auditUDPPort, bindAddress) ->
  defer = Q.defer()

  auditUDPServer = dgram.createSocket 'udp4'

  auditUDPServer.on 'listening', ->
    logger.info "Auditing UDP server listening on port #{auditUDPPort}"
    defer.resolve()

  auditUDPServer.on 'message', (msg, rinfo) ->
    logger.info "[Auditing UDP] Received message from #{rinfo.address}:#{rinfo.port}"
    auditing.processAudit msg

  auditUDPServer.bind auditUDPPort, bindAddress

  return defer

exports.start = (ports, done) ->
  bindAddress = config.get 'bindAddress'
  logger.info "Starting OpenHIM server on #{bindAddress}..."
  promises = []

  ensureKeystore ->

    if ports.httpPort or ports.httpsPort
      koaMiddleware.setupApp (app) ->
        promises.push startHttpServer(ports.httpPort, bindAddress, app).promise if ports.httpPort
        promises.push startHttpsServer(ports.httpsPort, bindAddress, app).promise if ports.httpsPort

    if ports.apiPort
      koaApi.setupApp (app) ->
        promises.push startApiServer(ports.apiPort, bindAddress, app).promise

    if ports.rerunHttpPort
      koaMiddleware.rerunApp (app) ->
        promises.push startRerunServer(ports.rerunHttpPort, app).promise

    if ports.tcpHttpReceiverPort
      koaMiddleware.tcpApp (app) ->
        promises.push startTCPServersAndHttpReceiver(ports.tcpHttpReceiverPort, app).promise

    if ports.pollingPort
      koaMiddleware.pollingApp (app) ->
        promises.push startPollingServer(ports.pollingPort, app).promise

    if ports.auditUDPPort
      promises.push startAuditUDPServer ports.auditUDPPort, bindAddress

    (Q.all promises).then ->
      workerAPI.startupWorker() if ports.rerunHttpPort
      startAgenda()
      done()


exports.stop = stop = (done) ->
  promises = []

  stopServer = (server, serverType) ->
    deferred = Q.defer()

    server.close ->
      logger.info "Stopped #{serverType} server"
      deferred.resolve()

    return deferred.promise

  promises.push stopServer(httpServer, 'HTTP') if httpServer
  promises.push stopServer(httpsServer, 'HTTPS') if httpsServer
  promises.push stopServer(apiHttpsServer, 'API HTTP') if apiHttpsServer
  promises.push stopServer(rerunServer, 'Rerun HTTP') if rerunServer
  promises.push stopServer(pollingServer, 'Polling HTTP') if pollingServer
  promises.push stopAgenda().promise if agenda

  auditUDPServer.close() if auditUDPServer

  if tcpHttpReceiver
    promises.push stopServer(tcpHttpReceiver, 'TCP HTTP Receiver')

    defer = Q.defer()
    tcpAdapter.stopServers -> defer.resolve()
    promises.push defer.promise

  # close active connection so that servers can stop
  for key, socket of activeHttpConnections
    socket.destroy()
  for key, socket of activeHttpsConnections
    socket.destroy()
  for key, socket of activeApiConnections
    socket.destroy()
  for key, socket of activeRerunConnections
    socket.destroy()
  for key, socket of activeTcpConnections
    socket.destroy()
  for key, socket of activePollingConnections
    socket.destroy()

  (Q.all promises).then ->
    httpServer = null
    httpsServer = null
    apiHttpsServer = null
    rerunServer = null
    tcpHttpReceiver = null
    pollingServer = null
    auditUDPServer = null
    agenda = null
    done()

lookupServerPorts = ->
  httpPort: config.router.httpPort
  httpsPort: config.router.httpsPort
  apiPort: config.api.httpsPort
  rerunPort: config.rerun.httpPort
  tcpHttpReceiverPort: config.tcpAdapter.httpReceiver.httpPort
  pollingPort: config.polling.pollingPort
  auditUDPPort: config.auditing.servers.udp.port if config.auditing.servers.udp.enabled

if not module.parent
  # start the server
  ports = lookupServerPorts()

  exports.start ports, ->
    # setup shutdown listeners
    process.on 'exit', stop
    # interrupt signal, e.g. ctrl-c
    process.on 'SIGINT', -> stop process.exit
    # terminate signal
    process.on 'SIGTERM', -> stop process.exit


#############################################
###   Restart the server - Agenda Job     ###
#############################################

restartServer = (config, done) ->
  # stop the server
  exports.stop ->
    ports = lookupServerPorts()
    exports.start ports, -> done()


exports.startRestartServerAgenda = (done) ->
  agenda = new Agenda db: { address: config.mongo.url }
  agenda.define 'Restart Server', {priority: 'high', concurrency: 1}, (job, done) -> restartServer config, done
  agenda.start()
  agenda.schedule "in 2 seconds", 'Restart Server'
  done()
