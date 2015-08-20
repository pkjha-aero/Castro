subroutine PROBINIT (init,name,namlen,problo,probhi)

  use bl_error_module
  use probdata_module
  use prob_params_module, only: center

  implicit none

  integer init, namlen
  integer name(namlen)
  double precision problo(2), probhi(2)

  integer untin,i

  namelist /fortin/ pert_factor,dens_base,pres_base,y_pert_center, &
       pert_width,gravity,do_isentropic,boundary_type, &
       frac

  !
  !     Build "probin" filename -- the name of file containing fortin namelist.
  !     
  integer, parameter :: maxlen = 256
  character probin*(maxlen)

  if (namlen .gt. maxlen) call bl_error("probin file name too long")

  do i = 1, namlen
     probin(i:i) = char(name(i))
  end do

  ! set namelist defaults here
  frac = 0.5

  do_isentropic = .false.

  !     Read namelists
  untin = 9
  open(untin,file=probin(1:namlen),form='formatted',status='old')
  read(untin,fortin)
  close(unit=untin)

  ! set center variable in prob_params_module
  center(1) = frac*(problo(1)+probhi(1))
  center(2) = frac*(problo(2)+probhi(2))

end subroutine PROBINIT


! ::: -----------------------------------------------------------
! ::: This routine is called at problem setup time and is used
! ::: to initialize data on each grid.  
! ::: 
! ::: NOTE:  all arrays have one cell of ghost zones surrounding
! :::        the grid interior.  Values in these cells need not
! :::        be set here.
! ::: 
! ::: INPUTS/OUTPUTS:
! ::: 
! ::: level     => amr level of grid
! ::: time      => time at which to init data             
! ::: lo,hi     => index limits of grid interior (cell centered)
! ::: nstate    => number of state components.  You should know
! :::		   this already!
! ::: state     <=  Scalar array
! ::: delta     => cell size
! ::: xlo,xhi   => physical locations of lower left and upper
! :::              right hand corner of grid.  (does not include
! :::		   ghost region).
! ::: -----------------------------------------------------------
subroutine ca_initdata(level,time,lo,hi,nscal, &
                       state,state_l1,state_l2,state_h1,state_h2, &
                       delta,xlo,xhi)
  use probdata_module
  use prob_params_module, only: center
  use meth_params_module, only : NVAR, URHO, UMX, UMY, UEDEN, UEINT, UFS, UTEMP
  use eos_module
  use eos_type_module
  
  implicit none

  integer level, nscal
  integer lo(2), hi(2)
  integer state_l1,state_l2,state_h1,state_h2
  double precision xlo(2), xhi(2), time, delta(2)
  double precision state(state_l1:state_h1,state_l2:state_h2,NVAR)

  integer i,j,npts_1d
  double precision H,z,xn(1),x,y,x1,y1,r1,const
  double precision, allocatable :: pressure(:), density(:), temp(:), eint(:)

  type (eos_t) :: eos_state
  
  ! first make a 1D initial model for the entire domain
  npts_1d = (2.d0*center(2)+1.d-8) / delta(2)

  npts_model = npts_1d

  allocate(pressure(0:npts_1d-1))
  allocate(density (0:npts_1d-1))
  allocate(temp    (0:npts_1d-1))
  allocate(eint    (0:npts_1d-1))

  const = pres_base/dens_base**gamma_const

  pressure(0) = pres_base
  density(0)  = dens_base

  ! only initialize the first species
  xn(1) = 1.d0

  ! compute the pressure scale height (for an isothermal, ideal-gas
  ! atmosphere)
  H = pres_base / dens_base / abs(gravity)

  do j=0,npts_1d-1

     ! initial guess
     temp(j) = 1000.d0

     if (do_isentropic) then
        z = dble(j) * delta(2)
        density(j) = dens_base*(gravity*dens_base*(gamma_const - 1.0)*z/ &
             (gamma_const*pres_base) + 1.d0)**(1.d0/(gamma_const - 1.d0))
     else
        z = (dble(j)+0.5d0) * delta(2)
        density(j) = dens_base * exp(-z/H)
     end if

     model_r(j) = z
     model_rho(j) = density(j)

     if (j .gt. 0) then
        pressure(j) = pressure(j-1) - &
             delta(2) * 0.5d0 * (density(j)+density(j-1)) * abs(gravity)
     end if

     eos_state%p = pressure(j)
     eos_state%T = temp(j)
     eos_state%rho = density(j)
     eos_state%xn(:) = xn(:)

     call eos(eos_input_rp, eos_state)

     eint(j) = eos_state%e
     temp(j) = eos_state%T

  end do

  
  ! add an isobaric perturbation
  x1 = center(1)
  y1 = y_pert_center

  do j=lo(2),hi(2)
     y = (dble(j)+0.5d0)*delta(2)
     do i=lo(1),hi(1)
        x = (dble(i)+0.5d0)*delta(1)

        r1 = sqrt( (x-x1)**2 +(y-y1)**2 ) / pert_width

        state(i,j,UTEMP) = temp(j) * (1.d0 + (pert_factor * (1.d0 + tanh(2.d0-r1))))
        state(i,j,UFS) = 1.d0

        eos_state%T = state(i,j,UTEMP)
        eos_state%rho = state(i,j,URHO)
        eos_state%p = pressure(j)
        eos_state%xn(:) = xn(:)

        call eos(eos_input_tp, eos_state)

        state(i,j,URHO) = eos_state%rho
        state(i,j,UEINT) = eos_state%e

        ! make state conservative
        state(i,j,UFS) = state(i,j,UFS)*state(i,j,URHO)
        state(i,j,UEINT) = state(i,j,UEINT)*state(i,j,URHO)

        ! assumes ke=0
        state(i,j,UEDEN) = state(i,j,UEINT)

        state(i,j,UMX:UMY) = 0.d0

     end do
  end do


  deallocate(pressure,density,temp,eint)

end subroutine ca_initdata

! ::: -----------------------------------------------------------

subroutine ca_initdata_maestro(lo,hi,MAESTRO_init_type, &
                               state,state_l1,state_l2,state_h1,state_h2, &
                               dx,dr,xlo,xhi,p0,MAESTRO_npts_model,level)

  use probdata_module
  use interpolate_module
  use eos_module
  use eos_type_module
  use meth_params_module, only : NVAR, URHO, UMX, UMY, UEDEN, UEINT, UFS, UTEMP
  use network, only: nspec

  implicit none

  integer lo(2), hi(2), MAESTRO_init_type, level
  integer MAESTRO_npts_model
  integer state_l1,state_l2,state_h1,state_h2
  double precision xlo(2), xhi(2), dx(2), dr
  double precision p0(0:MAESTRO_npts_model-1)
  double precision state(state_l1:state_h1,state_l2:state_h2,NVAR)

  ! local variables
  double precision ekin
  double precision pressure,entropy

  integer i,j,n

  type (eos_t) :: eos_state

  ! compute p0 and add pi if necessary
  do j = lo(2), hi(2)
     do i = lo(1), hi(1)
        if (MAESTRO_init_type .eq. 1) then
           ! set pressure = p0
           state(i,j,UEDEN) = p0(j)
        else
           ! set pressure = p0+pi
           state(i,j,UEDEN) = state(i,j,UEDEN) + p0(j)
        end if

     end do
  end do

  if (MAESTRO_init_type .eq. 1 .or. MAESTRO_init_type .eq. 2) then

     do j = lo(2), hi(2)
        do i = lo(1), hi(1)

           ! load pressure from our temporary storage field
           pressure = state(i,j,UEDEN)

           ! compute e and T
           eos_state%rho = state(i,j,URHO)
           eos_state%T = state(i,j,UTEMP)
           eos_state%p = pressure
           eos_state%xn(:) = state(i,j,UFS:UFS-1+nspec)

           call eos(eos_input_rp, eos_state)

           state(i,j,UEINT) = eos_state%e
           state(i,j,UTEMP) = eos_state%T

           ! compute kinetic energy
           ekin = 0.5*state(i,j,URHO)*(state(i,j,UMX)**2+state(i,j,UMY)**2)

           ! convert velocity to momentum
           state(i,j,UMX:UMY) = state(i,j,UMX:UMY)*state(i,j,URHO)

           ! compute rho*e
           state(i,j,UEINT) = state(i,j,URHO) * state(i,j,UEINT)

           ! compute rho*E = rho*e + ke
           state(i,j,UEDEN) = state(i,j,UEINT) + ekin

           ! convert X to rhoX
           do n = 1,nspec
              state(i,j,UFS+n-1) = state(i,j,URHO) * state(i,j,UFS+n-1)
           end do

        end do
     end do

  else if (MAESTRO_init_type .eq. 3) then

     do j = lo(2), hi(2)
        do i = lo(1), hi(1)

           ! load pressure from our temporary storage field
           pressure = state(i,j,UEDEN)

           ! compute rho and e
           eos_state%rho = state(i,j,URHO)
           eos_state%T = state(i,j,UTEMP)
           eos_state%p = pressure
           eos_state%xn(:) = state(i,j,UFS:UFS-1+nspec)

           call eos(eos_input_tp, eos_state)

           state(i,j,UEINT) = eos_state%e
           state(i,j,URHO) = eos_state%rho

           ! compute kinetic energy
           ekin = 0.5*state(i,j,URHO)*(state(i,j,UMX)**2+state(i,j,UMY)**2)

           ! convert velocity to momentum
           state(i,j,UMX:UMY) = state(i,j,UMX:UMY)*state(i,j,URHO)

           ! compute rho*e
           state(i,j,UEINT) = state(i,j,URHO) * state(i,j,UEINT)

           ! compute rho*E = rho*e + ke
           state(i,j,UEDEN) = state(i,j,UEINT) + ekin

           ! convert X to rhoX
           do n = 1,nspec
              state(i,j,UFS+n-1) = state(i,j,URHO) * state(i,j,UFS+n-1)
           end do

        end do
     end do

  else if (MAESTRO_init_type .eq. 4) then

     do j = lo(2), hi(2)
        do i = lo(1), hi(1)

           ! load pressure from our temporary storage field
           pressure = state(i,j,UEDEN)

           ! load entropy from our temporary storage field
           entropy = state(i,j,UEINT)

           ! compute kinetic energy
           ekin = 0.5*state(i,j,URHO)*(state(i,j,UMX)**2+state(i,j,UMY)**2)

           ! compute rho, T, and e

           eos_state%p = pressure
           eos_state%s = entropy
           eos_state%rho = state(i,j,URHO)
           eos_state%T = state(i,j,UTEMP)
           eos_state%xn(:) = state(i,j,UFS:UFS-1+nspec)
           
           call eos(eos_input_ps, eos_state)

           state(i,j,URHO) = eos_state%rho
           state(i,j,UTEMP) = eos_state%T
           state(i,j,UEINT) = eos_state%e

           ! convert velocity to momentum
           state(i,j,UMX:UMY) = state(i,j,UMX:UMY)*state(i,j,URHO)

           ! compute rho*e
           state(i,j,UEINT) = state(i,j,URHO) * state(i,j,UEINT)

           ! compute rho*E = rho*e + ke
           state(i,j,UEDEN) = state(i,j,UEINT) + ekin

           ! convert X to rhoX
           do n = 1,nspec
              state(i,j,UFS+n-1) = state(i,j,URHO) * state(i,j,UFS+n-1)
           end do

        end do
     end do

  end if

end subroutine ca_initdata_maestro

! ::: -----------------------------------------------------------

subroutine ca_initdata_makemodel(model,model_size,MAESTRO_npts_model, &
                                 rho0,tempbar,dx,r_model_start)

  use network, only: nspec
  use eos_module

  implicit none

  integer model_size,MAESTRO_npts_model
  double precision model(model_size,0:MAESTRO_npts_model-1)
  double precision rho0   (0:MAESTRO_npts_model-1)
  double precision tempbar(0:MAESTRO_npts_model-1)
  double precision dx(2)
  integer r_model_start
  call bl_error("SHOULDN'T BE IN INITDATA_MAKEMODEL FOR THIS PROBELM")

end subroutine ca_initdata_makemodel

! ::: -----------------------------------------------------------

subroutine ca_initdata_overwrite(lo,hi, &
     state,state_l1,state_l2,state_h1,state_h2, &
     model,model_size,MAESTRO_npts_model,dx,dr, &
     xlo,xhi,r_model_start)

  use bl_error_module
  use meth_params_module, only: NVAR
  implicit none

  integer lo(2), hi(2), r_model_start
  integer model_size,MAESTRO_npts_model
  integer state_l1,state_l2,state_h1,state_h2
  double precision state(state_l1:state_h1,state_l2:state_h2,NVAR)
  double precision model(model_size,0:MAESTRO_npts_model-1)
  double precision dx(2), xlo(2), xhi(2), dr

  call bl_error("SHOULDN'T BE IN INITDATA_OVERWRITE FOR THIS PROBELM")


end subroutine ca_initdata_overwrite

