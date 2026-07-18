/** "59m", "1d 23h", "3h 5m", "—" for null/past. */
export function humanizeUntil(iso: string | null, now: Date): string {
  if (!iso) return "—";
  const target = new Date(iso).getTime();
  const deltaSeconds = Math.floor((target - now.getTime()) / 1000);
  if (!Number.isFinite(deltaSeconds) || deltaSeconds <= 0) return "now";
  const days = Math.floor(deltaSeconds / 86_400);
  const hours = Math.floor((deltaSeconds % 86_400) / 3_600);
  const minutes = Math.floor((deltaSeconds % 3_600) / 60);
  if (days > 0) return hours > 0 ? `${days}d ${hours}h` : `${days}d`;
  if (hours > 0) return minutes > 0 ? `${hours}h ${minutes}m` : `${hours}h`;
  return `${Math.max(1, minutes)}m`;
}
