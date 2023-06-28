#!/usr/bin/env node

const os = require('os');
const child_process = require('child_process');

const nodeToZigOS = {
	'linux': 'linux',
	'win32': 'windows',
	'darwin': 'macos',
};

const nodeToZigCPU = {
	'arm': 'arm',
	'arm64': 'aarch64',
	'x64': 'x86_64',
};

const packageName = `@openbible/usfm-${nodeToZigCPU[os.arch()]}-${nodeToZigOS[os.platform()]}`;

const binPath = `${packageName}/bin/usfm${os.platform() == 'win32' ? '.exe' : ''}`;
const absBinPath = require.resolve(binPath);

child_process.execFileSync(absBinPath, process.argv.slice(2), { stdio: "inherit" });
