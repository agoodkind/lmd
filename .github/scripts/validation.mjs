export function requireCondition(condition, message) {
  if (!condition) throw new Error(message);
}
