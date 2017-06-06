import auth from "basic-auth";
import Q from "q";
import logger from "winston";
import crypto from "crypto";
import SDC from "statsd-client";
import os from "os";
import { Client } from "../model/clients";
import config from "../config/config";

const statsdServer = config.get("statsd");
const application = config.get("application");

const domain = `${os.hostname()}.${application.name}.appMetrics`;
const sdc = new SDC(statsdServer);

export function authenticateUser(ctx, done) {
	return Client.findOne({ _id: ctx.request.header.clientid }, (err, client) => {
		ctx.authenticated = client;
		ctx.parentID = ctx.request.header.parentid;
		ctx.taskID = ctx.request.header.taskid;
		return done(null, client);
	});
}


/*
 * Koa middleware for authentication by basic auth
 */
export function* koaMiddleware(next) {
	let startTime;
	if (statsdServer.enabled) { startTime = new Date(); }
	const authenticateUser = Q.denodeify(exports.authenticateUser);
	yield authenticateUser(this);

	if (this.authenticated != null) {
		if (statsdServer.enabled) { sdc.timing(`${domain}.rerunBypassAuthenticationMiddleware`, startTime); }
		return yield next;
	} else {
		this.authenticated =
			{ ip: "127.0.0.1" };
		// This is a public channel, allow rerun
		if (statsdServer.enabled) { sdc.timing(`${domain}.rerunBypassAuthenticationMiddleware`, startTime); }
		return yield next;
	}
}

