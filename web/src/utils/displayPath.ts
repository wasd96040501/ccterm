export function displayPath(filePath: string, cwd: string | null): string {
  if (!cwd) return filePath
  const cwdSlash = cwd.endsWith('/') ? cwd : cwd + '/'
  if (filePath.startsWith(cwdSlash)) return filePath.slice(cwdSlash.length)
  return filePath
}
