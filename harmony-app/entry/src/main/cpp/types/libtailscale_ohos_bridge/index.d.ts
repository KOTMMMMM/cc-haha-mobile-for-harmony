export const tsVersion: () => string;
export const tsHello: () => string;
export const tsStart: (stateDir: string, deviceModel: string,
  osVersion: string, controlURL: string) => Promise<string>;
export const tsRestartWithTun: (stateDir: string, deviceModel: string,
  osVersion: string, controlURL: string, fd: number) => Promise<string>;
export const tsLoginWithAuthKey: (authKey: string) => Promise<string>;
export const tsAuthUrl: () => Promise<string>;
export const tsVpnConfig: () => Promise<string>;
export const tsStatus: () => Promise<string>;
export const tsSnapshot: () => Promise<string>;
export const tsStop: () => Promise<string>;
export const tsTunFdProbe: (fd: number) => string;
export const tsNetworkChanged: (interfaceName: string) => Promise<string>;
