// Pikakassa-näkymä. Asettelu ja maksupopup: ../pos-screen.js. Rpc tulee hallinnan sb.js:stä.
import { rpc, fn } from '../sb.js';
import { renderPos } from '../pos-screen.js';

// Kokeilutila (?mock=1): Edge-kutsut (Kortti puhelimella) simuloidaan selaimessa (options-mock.js fn), ei verkkoa.
const MOCK = () => new URLSearchParams(location.search).get('mock') === '1';

export function render(opts) {
  const mockFn = MOCK() && typeof globalThis.__adminMock?.fn === 'function' ? globalThis.__adminMock.fn : null;
  return renderPos({ ...opts, rpc, fn: mockFn || fn });
}
