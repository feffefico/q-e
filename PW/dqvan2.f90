!
! Copyright (C) 2001 PWSCF group
! This file is distributed under the terms of the
! GNU General Public License. See the file `License'
! in the root directory of the present distribution,
! or http://www.gnu.org/copyleft/gpl.txt .
!
!-----------------------------------------------------------------------
subroutine dqvan2 (ngy, ih, jh, np, qmod, dqg, ylmk0, dylmk0, ipol)
  !-----------------------------------------------------------------------
  !
  !    This routine computes the derivatives of the fourier transform of
  !    the Q function needed in stress assuming that the radial fourier
  !    trasform is already computed and stored in table qrad.
  !
  !    The formula implemented here is
  !
  !     dq(g,l,k) = sum_lm (-i)^l ap(lm,l,k) *
  !                ( yr_lm(g^) dqrad(g,l,l,k) + dyr_lm(g^) qrad(g,l,l,k))
  !
  !     here the dummy variables
  !
#include "machine.h"
  use pwcom  
  implicit none
  integer :: ngy, ih, jh, np, ipol  
  ! input: the number of G vectors to compute
  ! input: the first index of Q
  ! input: the second index of Q
  ! input: the number of the pseudopotential
  ! input: the polarization of the derivative

  real(kind=DP) :: ylmk0 (ngy, lqx * lqx), dylmk0 (ngy, lqx * lqx), &
       qmod (ngy)
  ! the spherical harmonics
  ! the spherical harmonics derivetives
  ! input: moduli of the q+g vectors
  complex(kind=DP) :: dqg (ngy)  
  ! output: the fourier transform of interest
  !
  !     here the local variables
  !

  complex(kind=DP) :: sig  
  ! (-i)^L

  integer :: nb, mb, nmb, ivl, jvl, ig, lp, l, lm, i0, i1, i2, i3  
  ! the atomic index corresponding to ih
  ! the atomic index corresponding to jh
  ! combined index (nb,mb)
  ! the lm corresponding to ih
  ! the lm corresponding to jh
  ! counter on g vectors
  ! the actual LM
  ! the angular momentum L
  ! the possible LM's compatible with ih,j
  ! counters for interpolation table

  real(kind=DP) :: sixth, dqi, qm, px, ux, vx, wx, uvx, pwx, work, work1  
  ! 1 divided by six
  ! 1 divided dq
  ! qmod/dq
  ! measures for interpolation table
  ! auxiliary variables for intepolation
  ! auxiliary variable
  ! auxiliary variable
  !
  !     compute the indices which correspond to ih,jh
  !
  sixth = 1.d0 / 6.d0  
  dqi = 1 / dq  
  nb = indv (ih, np)  
  mb = indv (jh, np)  
  if (nb.ge.mb) then  
     nmb = nb * (nb - 1) / 2 + mb  
  else  
     nmb = mb * (mb - 1) / 2 + nb  
  endif
  ivl = nhtol (ih, np) * nhtol (ih, np) + nhtom (ih, np)  


  jvl = nhtol (jh, np) * nhtol (jh, np) + nhtom (jh, np)  
  if (nb.gt.nbrx) call error (' qvan2 ', ' nb.gt.nbrx ', nb)  
  if (mb.gt.nbrx) call error (' qvan2 ', ' mb.gt.nbrx ', mb)  
  if (ivl.gt.nlx) call error (' qvan2 ', ' ivl.gt.nlx  ', ivl)  

  if (jvl.gt.nlx) call error (' qvan2 ', ' jvl.gt.nlx  ', jvl)  
  call setv (2 * ngy, 0.d0, dqg, 1)  
  !
  !    and make the sum over the non zero LM
  !
  do lm = 1, lpx (ivl, jvl)  
     lp = lpl (ivl, jvl, lm)  
     !
     !     extraction of angular momentum l from lp:
     !
     if (lp.eq.1) then  
        l = 1  
     elseif ( (lp.ge.2) .and. (lp.le.4) ) then  
        l = 2  
     elseif ( (lp.ge.5) .and. (lp.le.9) ) then  
        l = 3  
     elseif ( (lp.ge.10) .and. (lp.le.16) ) then  
        l = 4  
     elseif ( (lp.ge.17) .and. (lp.le.25) ) then  
        l = 5  
     elseif ( (lp.ge.26) .and. (lp.le.36) ) then  
        l = 6
     elseif ( (lp.ge.37) .and. (lp.le.49) ) then  
        l = 7
     else
        call error (' qvan ', ' lp.gt.49 ', lp)  
     endif

     sig = (0.d0, - 1.d0) ** (l - 1)  
     sig = sig * ap (lp, ivl, jvl)  
     do ig = 1, ngy  
        !
        ! calculate quantites depending on the module of G only when needed
        !
        if (ig.eq.1.or.abs (qmod (ig) - qmod (ig - 1) ) .gt.1.0d-6) then
           qm = qmod (ig) * dqi  
           px = qm - int (qm)  
           ux = 1.d0 - px  
           vx = 2.d0 - px  
           wx = 3.d0 - px  
           i0 = qm + 1  
           i1 = i0 + 1  
           i2 = i0 + 2  
           i3 = i0 + 3  
           uvx = ux * vx * sixth  

           pwx = px * wx * 0.5d0  

           work = qrad (i0, nmb, l, np) * uvx * wx + &
                  qrad (i1, nmb, l, np) * pwx * vx - &
                  qrad (i2, nmb, l, np) * pwx * ux + &
                  qrad (i3, nmb, l, np) * px * uvx
           work1 = - qrad(i0, nmb, l, np) * (ux*vx + vx*wx + ux*wx) * sixth &
                   + qrad(i1, nmb, l, np) * (wx*vx - px*wx - px*vx) * 0.5d0 &
                   - qrad(i2, nmb, l, np) * (wx*ux - px*wx - px*ux) * 0.5d0 &
                   + qrad(i3, nmb, l, np) * (ux*vx - px*ux - px*vx) * sixth

           work1 = work1 * dqi  
        end if

        dqg (ig) = dqg (ig) + sig * dylmk0 (ig, lp) * work  
        if (qmod (ig) .gt.1.d-9) dqg (ig) = dqg (ig) + &
            sig * ylmk0 (ig, lp) * work1 * g (ipol, ig) / qmod (ig)
     enddo
  enddo
  return  

end subroutine dqvan2

