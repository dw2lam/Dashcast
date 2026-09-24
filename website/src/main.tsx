import React from 'react';
import ReactDOM from 'react-dom/client';
import App from './App';
import { gsap, ScrollTrigger, refreshOnLayoutChange } from './lib/motion';
import { installNavigation } from './lib/navigate';
import './styles/global.css';

if (import.meta.env.DEV) {
  Object.assign(window, { __gsap: gsap, __ST: ScrollTrigger });
}

const root = document.getElementById('root')!;
refreshOnLayoutChange(root);
installNavigation();

ReactDOM.createRoot(root).render(
  <React.StrictMode>
    <App />
  </React.StrictMode>,
);
