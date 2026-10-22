import { StrictMode } from 'react'
import { createRoot } from 'react-dom/client'
import './index.css'
import App from './App.tsx'
import RiderApp from './RiderApp.tsx'
import { CompanyStaffLogin } from './CompanyStaffApp.tsx'

createRoot(document.getElementById('root')!).render(
  <StrictMode>
    {window.location.pathname === '/rider' ? <RiderApp /> : window.location.pathname === '/company-staff' ? <CompanyStaffLogin /> : <App />}
  </StrictMode>,
)
