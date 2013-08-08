module riemann_support

  use bl_constants_module
  use bl_error_module
  use bl_types
  use eos_type_module
  use eos_module
  use network

  implicit none

contains

  subroutine shock(pstar, rho_s, u_s, p_s, xn, &
                   gammaE_bar, gammaC_bar, Z_s, W_s, &
                   verbose_in)

    real (kind=dp_t), intent(in) :: pstar, rho_s, u_s, p_s, gammaE_bar, gammaC_bar
    real (kind=dp_t), intent(in) :: xn(nspec)
    real (kind=dp_t), intent(out) :: Z_s, W_s
    logical, optional, intent(in) :: verbose_in

    real (kind=dp_t) :: e_s

    type (eos_t) :: eos_state
    
    real (kind=dp_t) :: rhostar_s, taustar_s
    real (kind=dp_t) :: dW2dpstar, dWdpstar
    real (kind=dp_t) :: C
    real (kind=dp_t) :: f, fprime, dW
    
    real (kind=dp_t) :: p_e, p_rho, p_tau
    real (kind=dp_t) :: gammaE_s, gammaE_star

    real (kind=dp_t), parameter :: tol_p = 1.e-6_dp_t

    real (kind=dp_t), parameter :: smallrho = 100.d0
    
    integer :: iter, i
    integer, parameter :: max_iters = 100
    real (kind=dp_t) :: rhostar_hist(max_iters), Ws_hist(max_iters)

    real (kind=dp_t) :: tol = 1.e-8_dp_t

    logical :: converged

    logical :: verbose

    if (present(verbose_in)) then
       verbose = verbose_in
    else
       verbose = .false.
    endif


    ! compute the Z_s function for a shock following C&G Eq. 20 and
    ! 23.  Here the "_s" variables are the state (L or R) that we are
    ! connecting to the star region through a shock.

    ! first we need to compute W_s -- this is iterative because of the
    ! nonlinear EOS.  We use the R-H jump conditions + the EOS

    ! get the s-state energy, e_s
    eos_state%rho = rho_s
    eos_state%p = p_s
    eos_state%xn(:) = xn(:)
    eos_state%T = 100000.0   ! we need an initial guess

    call eos(eos_input_rp, eos_state, .false.)

    e_s = eos_state%e

    ! to kick things off, we need a guess for W_s.  We'll use the
    ! approximation from Colella & Glaz (Eq. 34), which in turn
    ! makes an approximation for gammaE_star, using equation 31.
    gammaE_s = p_s/(rho_s*e_s) + ONE
    
    gammaE_star = gammaE_s + &
         TWO*(ONE - gammaE_bar/gammaC_bar)*(gammaE_bar - ONE) * &
         (pstar - p_s)/(pstar + p_s)

    !gammaE_star = min(FIVE3RD, max(FOUR3RD, gammaE_star))

    ! in the limit that pstar - p_s is small, drop down to the
    ! Lagrangian sound speed
    if (verbose) then
       print *, 'pstar, ps = ', pstar, p_s, gammaE_s, gammaE_star
       print *, (pstar/rho_s - (gammaE_star - ONE)/(gammaE_s - ONE)*p_s/rho_s)
       print *, (pstar + HALF*(gammaE_star - ONE)*(pstar + p_s))
    endif

    if (pstar - p_s < tol_p*p_s) then
       W_s = sqrt(eos_state%gam1*p_s*rho_s)
    else
       W_s = sqrt( (pstar - p_s)* &
                   (pstar + HALF*(gammaE_star - ONE)*(pstar + p_s)) / &
                   (pstar/rho_s - (gammaE_star - ONE)/(gammaE_s - ONE)*p_s/rho_s))
    endif


    ! Newton iterations -- we are zeroing the energy R-H jump condition
    ! W^2 [e] = 1/2 [p^2]
    !
    ! we write f(W) = W^2 (e(pstar, rhostar_s) - e_s) - (1/2)(pstar^2 - p_s)
    !
    ! and then compute f'


    ! we need rhostar -- get it from the R-H conditions
    taustar_s = (ONE/rho_s) - (pstar - p_s)/W_s**2

    if (taustar_s < ZERO) then
       rhostar_s = smallrho
       W_s = sqrt((pstar - p_s)/(ONE/rho_s - ONE/rhostar_s))
    endif

    converged = .false.
    iter = 1
    do while (.not. converged .and. iter < max_iters)

       call W_s_shock(W_s, pstar, rho_s, p_s, e_s, xn, rhostar_s, eos_state, f, fprime)
       dW = -f/fprime

       if (abs(dW) < tol*W_s) converged = .true.
          
       W_s = min(1.1d0*W_s, max(0.9d0*W_s,W_s + dW))

       ! store some history
       rhostar_hist(iter) = rhostar_s
       Ws_hist(iter) = W_s

       iter = iter + 1

    enddo

    if (.not. converged) then
       do i = 1, max_iters-1
          print *, i, rhostar_hist(i), Ws_hist(i)
       enddo

       call bl_error("ERROR: shock did not converge", abs(dW)/W_s)
    endif

    ! now that we have W_s, we can get rhostar from the R-H conditions
    ! (C&G Eq. 12)
    taustar_s = (ONE/rho_s) - (pstar - p_s)/W_s**2
    rhostar_s = ONE/taustar_s

    ! next we compute the derivative dW_s/dpstar -- the paper gives
    ! dW**2/dpstar (Eq. 23), so we take 1/2W of that
    C = sqrt(eos_state%gam1*pstar*rhostar_s)

    p_e = eos_state%dpdT/eos_state%dedT
    p_rho = eos_state%dpdr - eos_state%dpdT*eos_state%dedr/eos_state%dedT

    p_tau = -rhostar_s**2*p_rho

    dW2dpstar = (C**2 - W_s**2)*W_s**2 / &
         ((HALF*(pstar + p_s)*p_e - p_tau)*(pstar - p_s))

    dWdpstar = HALF*dW2dpstar/W_s
    
    ! finally compute Z_s
    Z_s = W_s**2/(W_s - dWdpstar*(pstar - p_s))

  end subroutine shock

  subroutine W_s_shock(W_s, pstar, rho_s, p_s, e_s, xn, rhostar_s, eos_state, f, fprime)

    real (kind=dp_t), intent(in) :: W_s, pstar, rho_s, p_s, e_s, xn(nspec)
    real (kind=dp_t), intent(out) :: rhostar_s, f, fprime
    type (eos_t), intent(inout) :: eos_state

    real (kind=dp_t) :: taustar_s
    real (kind=dp_t) :: dedrho_p

    ! we need rhostar -- get it from the R-H conditions
    taustar_s = (ONE/rho_s) - (pstar - p_s)/W_s**2
    rhostar_s = ONE/taustar_s
      
    ! get the thermodynamics
    eos_state%rho = rhostar_s
    eos_state%p = pstar
    eos_state%xn(:) = xn(:)
    eos_state%T = 100000.0   ! we need an initial guess

    call eos(eos_input_rp, eos_state, .false.)

    ! compute the correction
    f = W_s**2 * (eos_state%e - e_s) - HALF*(pstar**2 - p_s**2)

    ! we need de/drho at constant p -- this is not returned by the EOS
    dedrho_p = eos_state%dedr - eos_state%dedT*eos_state%dpdr/eos_state%dpdT
       
    fprime = TWO*W_s*(eos_state%e - e_s) - TWO*dedrho_p*(pstar - p_s)*rhostar_s**2/W_s

  end subroutine W_s_shock

  subroutine rarefaction(pstar, rho_s, u_s, p_s, xn, iwave, Z_s, W_s, rhostar)

    real (kind=dp_t), intent(in) :: pstar, rho_s, u_s, p_s
    real (kind=dp_t), intent(in) :: xn(nspec)
    integer, intent(in) :: iwave
    real (kind=dp_t), intent(out) :: Z_s, W_s
    real (kind=dp_t), intent(out), optional :: rhostar

    real (kind=dp_t) :: dp, dp2
    real (kind=dp_t) :: p, u, tau
    real (kind=dp_t) :: dtaudp1, dtaudp2, dtaudp3, dtaudp4
    real (kind=dp_t) :: dudp1, dudp2, dudp3, dudp4

    integer, parameter :: npts = 200

    type (eos_t) :: eos_state

    integer :: i

    ! Compute Z_s = C for a rarefaction connecting the state to the star
    ! region by integrating the Riemann invariant from p_s to pstar.
    ! This means solving a system of ODEs.  We use 4th-order R-K.

    tau = ONE/rho_s
    u = u_s
    p = p_s

    dp = (pstar - p_s)/npts

    do i = 1, npts

       dp2 = HALF*dp

       ! do 4th-order RT
       call riemann_invariant_rhs(p, tau, u, &
                                  xn, iwave, dtaudp1, dudp1)

       call riemann_invariant_rhs(p+dp2, tau+dp2*dtaudp1, u+dp2*dudp1, &
                                  xn, iwave, dtaudp2, dudp2)

       call riemann_invariant_rhs(p+dp2, tau+dp2*dtaudp2, u+dp2*dudp2, &
                                  xn, iwave, dtaudp3, dudp3)

       call riemann_invariant_rhs(p+dp, tau+dp*dtaudp3, u+dp*dudp3, &
                                  xn, iwave, dtaudp4, dudp4)

       p = p + dp
       u = u + SIXTH*dp*(dudp1 + TWO*dudp2 + TWO*dudp3 + dudp4)
       tau = tau + SIXTH*dp*(dtaudp1 + TWO*dtaudp2 + TWO*dtaudp3 + dtaudp4)

    enddo

    !print *, 'done with rarefaction integration', p, u

    ! Z_s is just the Lagrangian sound speed
    eos_state%rho = ONE/tau
    eos_state%p = p
    eos_state%xn(:) = xn(:)
    eos_state%T = 100000.0_dp_t   ! need an initial guess

    call eos(eos_input_rp, eos_state, .false.)

    Z_s = sqrt(eos_state%gam1*p/tau)

    ! also need W_s -- this is C&G Eq. 16.  u above is ustar_s.
    if (u == u_s) then
       W_s = Z_s
    else
       W_s = abs(pstar - p_s)/abs(u - u_s)
    endif

    if (present(rhostar)) then
       rhostar = ONE/tau
    endif

  end subroutine rarefaction


  subroutine rarefaction_to_u(rho_s, u_s, p_s, xn, iwave, xi, rho, p, u, &
                              verbose_in)

    real (kind=dp_t), intent(in) :: rho_s, u_s, p_s, xi
    real (kind=dp_t), intent(in) :: xn(nspec)
    integer, intent(in) :: iwave
    real (kind=dp_t), intent(out) :: rho, p, u
    logical, optional, intent(in) :: verbose_in

    real (kind=dp_t) :: du, du2
    real (kind=dp_t) :: tau
    real (kind=dp_t) :: dtaudu1, dtaudu2, dtaudu3, dtaudu4
    real (kind=dp_t) :: dpdu1, dpdu2, dpdu3, dpdu4

    real (kind=dp_t) :: ustop, c

    logical :: finished 

    integer, parameter :: npts = 200

    type (eos_t) :: eos_state

    real (kind=dp_t) :: tol = 1.e-8

    integer :: i

    logical :: verbose

    if (present(verbose_in)) then
       verbose = verbose_in
    else
       verbose = .false.
    endif

    ! here we integrate the Riemann invariants for a rarefaction up to
    ! some intermediate u (between u_s and ustar).  This accounts for
    ! the fact that we are inside the rarefaction.  
    
    ! We reformulate the system of ODEs from C&G Eq. 13 to make u the
    ! dependent variable.  Now we solve:

    ! we actually don't know the stopping point.  For the 1-wave, we
    ! stop at u = xi + c, for the 3-wave, we stop at u = xi - c, where
    ! c is computed as we step.

    ! dp/du =  C; dtau/du = -1/C   for the 1-wave
    ! dp/du = -C; dtau/du =  1/C   for the 3-wave

    tau = ONE/rho_s
    u = u_s
    p = p_s

    ! estimate
    ! compute c
    eos_state%rho = ONE/tau
    eos_state%p = p
    eos_state%xn(:) = xn(:)
    eos_state%T = 100000.0_dp_t   ! need an initial guess

    call eos(eos_input_rp, eos_state, .false.)

    c = sqrt(eos_state%gam1*p*tau)

    if (iwave == 1) then
       ustop = xi + c
    else if (iwave == 3) then
       ustop = xi - c
    endif

    du = (ustop - u_s)/npts

    finished = .false.

    if (verbose) print *, 'integrating from u: ', u, ustop, xi, c

    do while (.not. finished)

       du2 = HALF*du

       ! do 4th-order RT
       call riemann_invariant_rhs2(u, tau, p, &
                                   xn, iwave, dtaudu1, dpdu1)

       call riemann_invariant_rhs2(u+du2, tau+du2*dtaudu1, p+du2*dpdu1, &
                                   xn, iwave, dtaudu2, dpdu2)

       call riemann_invariant_rhs2(u+du2, tau+du2*dtaudu2, p+du2*dpdu2, &
                                   xn, iwave, dtaudu3, dpdu3)

       call riemann_invariant_rhs2(u+du, tau+du*dtaudu3, p+du*dpdu3, &
                                   xn, iwave, dtaudu4, dpdu4)

       u = u + du
       p = p + SIXTH*du*(dpdu1 + TWO*dpdu2 + TWO*dpdu3 + dpdu4)
       tau = tau + SIXTH*du*(dtaudu1 + TWO*dtaudu2 + TWO*dtaudu3 + dtaudu4)

       ! compute c
       eos_state%rho = ONE/tau
       eos_state%p = p
       eos_state%xn(:) = xn(:)
       eos_state%T = 100000.0_dp_t   ! need an initial guess

       !print *, 'calling EOS:',  tau, p, xn
       call eos(eos_input_rp, eos_state, .false.)

       c = sqrt(eos_state%gam1*p*tau)

       ! check the step size
       if (iwave == 1) then
          ustop = xi + c
       else if (iwave == 3) then
          ustop = xi - c
       endif

       if (du*u > 0.0d0) then
          do while (abs(u + du) > abs(ustop) .and. du /= ZERO)
             du = 0.5d0*du
          enddo
       else
          if (u > 0.0d0) then
             do while (u + du < ustop .and. du /= ZERO)
                du = 0.5d0*du
             enddo

          else
             do while (u + du > ustop .and. du /= ZERO)
                du = 0.5d0*du
             enddo
          endif
       endif

       if (abs(du) < tol*abs(u)) then
          finished = .true.
       endif
       
    enddo

    rho = ONE/tau

  end subroutine rarefaction_to_u


  subroutine riemann_invariant_rhs(p, tau, u, xn, iwave, dtaudp, dudp)

    ! here, p is out independent variable, and tau, u are the 
    ! dependent variables.  We return the derivatives of these
    ! wrt p for integration.

    real (kind=dp_t), intent(in) :: tau, u, p, xn(nspec)
    real (kind=dp_t), intent(out) :: dtaudp, dudp
    integer, intent(in) :: iwave

    type (eos_t) :: eos_state
    real (kind=dp_t) :: C

    ! get the thermodynamics
    eos_state%rho = ONE/tau
    eos_state%p = p
    eos_state%xn(:) = xn(:)
    eos_state%T = 100000.0_dp_t   ! need an initial guess

    call eos(eos_input_rp, eos_state, .false.)

    C = sqrt(eos_state%gam1*p/tau)

    dtaudp = -ONE/C**2

    if (iwave == 1) then
       dudp = -ONE/C
    else if (iwave == 3) then
       dudp = ONE/C
    endif
    
  end subroutine riemann_invariant_rhs


  subroutine riemann_invariant_rhs2(u, tau, p, xn, iwave, dtaudu, dpdu)

    ! here, u is out independent variable, and tau, p are the 
    ! dependent variables.  We return the derivatives of these
    ! wrt u for integration.

    real (kind=dp_t), intent(in) :: tau, u, p, xn(nspec)
    real (kind=dp_t), intent(out) :: dtaudu, dpdu
    integer, intent(in) :: iwave

    type (eos_t) :: eos_state
    real (kind=dp_t) :: C

    ! get the thermodynamics
    eos_state%rho = ONE/tau
    eos_state%p = p
    eos_state%xn(:) = xn(:)
    eos_state%T = 100000.0_dp_t   ! need an initial guess

    call eos(eos_input_rp, eos_state, .false.)

    C = sqrt(eos_state%gam1*p/tau)

    if (iwave == 3) then
       dpdu = C
       dtaudu = -ONE/C

    else if (iwave == 1) then
       dpdu = -C
       dtaudu = ONE/C
    endif
    
  end subroutine riemann_invariant_rhs2

end module riemann_support
