import React from 'react'
import { createRoot } from 'react-dom/client'
import App from './App'
import Dashboard from './Dashboard'
import './styles.css'
import './dashboard.css'

createRoot(document.getElementById('root')!).render(
  <React.StrictMode>
    {new URLSearchParams(window.location.search).has('dashboard') ? <Dashboard /> : <App />}
  </React.StrictMode>,
)
