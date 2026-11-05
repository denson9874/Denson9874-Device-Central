// The one piece of node:buffer the Worker uses (nodejs_compat provides it; Node runs the tests).
declare module "node:buffer" {
	export const Buffer: { from(data: Uint8Array): { toString(encoding: "base64"): string } };
}
