export interface Infobase {
  name: string;
  server: string;
  ref: string;
  filePath: string;
  isServer: boolean;
  version: string;
  defaultVersion: string;
}

export interface PlatformMatch {
  path: string | null;
  matchedVersion: string | null;
  usedFallback: boolean;
  warning: string | null;
}

export interface VersionMismatch {
  client: string;
  server: string;
}

export type StatusTone = 'muted' | 'success' | 'error' | 'progress';

export interface FileItem {
  path: string;
  checked: boolean;
}

export interface PanelState {
  windows: boolean;
  projectPath: string;
  bases: { name: string; label: string }[];
  selectedBase: number;
  files: FileItem[];
  foundText: string;
  foundTone: StatusTone;
  statusText: string;
  statusTone: StatusTone;
  loading: boolean;
  updateDatabase: boolean;
  openConfigurator: boolean;
}
