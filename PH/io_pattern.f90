!
! Copyright (C) 2001 PWSCF group
! This file is distributed under the terms of the
! GNU General Public License. See the file `License'
! in the root directory of the present distribution,
! or http://www.gnu.org/copyleft/gpl.txt .
!
!---------------------------------------------------------------------
subroutine io_pattern (fildrho,nirr,npert,u,iflag)
!---------------------------------------------------------------------
  use pwcom
  use parameters, only : DP
#ifdef PARA
  use para
#endif
  implicit none
#ifdef PARA
  include 'mpif.h'  
#endif
!
!   the i/o variables first
!
  integer :: nirr, npert(3*nat), iflag
  complex(kind=DP) :: u(3*nat,3*nat)
  character::  fildrho*(*)   ! name of the file
  character::  filname*42    ! complete name of the file
!
!   here the local variables
!
  integer :: i,iunit
  logical :: exst

  if (abs(iflag).ne.1) call error('io_pattern','wrong iflag',1+abs(iflag))

#ifdef PARA
!  if (iflag.eq.+1 .and. (me.ne.1.or.mypool.ne.1)) return
#endif

  iunit = 4
  filname = trim(fildrho) //".pat"
  call seqopn(iunit,filname,'formatted',exst)

  if (iflag.gt.0) then
     write (6,*) 'WRITING PATTERNS ON FILE ', filname
     write(iunit,*) nirr
     write(iunit,*) (npert(i),i=1,nirr)
     write(iunit,*) u
  else
     write (6,*) 'READING PATTERNS FROM FILE ', filname
     read(iunit,*) nirr
     read(iunit,*) (npert(i),i=1,nirr)
     read(iunit,*) u
  end if

  close (iunit)

  return  
end subroutine io_pattern
