export function parseVersion(versionString: string | null | undefined): number[] | null {
  if (!versionString) {
    return null;
  }
  const parts = versionString.trim().split('.');
  if (parts.length < 2) {
    return null;
  }
  const nums: number[] = [];
  for (const part of parts) {
    if (!/^\d+$/.test(part)) {
      return null;
    }
    nums.push(Number(part));
  }
  while (nums.length < 4) {
    nums.push(0);
  }
  return nums.slice(0, 4);
}

export function compareVersions(a: string, b: string): number {
  const av = parseVersion(a) ?? [0, 0, 0, 0];
  const bv = parseVersion(b) ?? [0, 0, 0, 0];
  for (let i = 0; i < 4; i++) {
    if (av[i] !== bv[i]) {
      return av[i] - bv[i];
    }
  }
  return 0;
}

export function versionPrefixMatch(installed: string, required: string): boolean {
  const reqParts = required.trim().replace(/\.$/, '').split('.');
  const instParts = installed.trim().split('.');
  if (instParts.length < reqParts.length) {
    return false;
  }
  for (let i = 0; i < reqParts.length; i++) {
    if (instParts[i] !== reqParts[i]) {
      return false;
    }
  }
  return true;
}
