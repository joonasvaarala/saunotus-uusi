// Pikakassa-näkymä. Asettelu ja maksupopup: ../pos-screen.js. Rpc tulee hallinnan sb.js:stä.
import { rpc, fn } from '../sb.js';
import { renderPos } from '../pos-screen.js';

export function render(opts) {
  return renderPos({ ...opts, rpc, fn });
}
