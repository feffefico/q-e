!
! Copyright (C) 2013 Quantum ESPRESSO group
! This file is distributed under the terms of the
! GNU General Public License. See the file `License'
! in the root directory of the present distribution,
! or http://www.gnu.org/copyleft/gpl.txt .
!
!----------------------------------------------------------------------------
SUBROUTINE run_driver ( srvaddress, exit_status ) 
  !!
  !! Driver for IPI
  !!
  USE io_global,        ONLY : stdout, ionode, ionode_id
  USE parameters,       ONLY : ntypx, npk, lmaxx
  USE check_stop,       ONLY : check_stop_init
  USE mp_global,        ONLY : mp_bcast, mp_global_end, intra_image_comm
  USE control_flags,    ONLY : gamma_only, conv_elec, istep, ethr, lscf, lmd
  USE cellmd,           ONLY : lmovecell
  USE force_mod,        ONLY : lforce, lstres
  USE ions_base,        ONLY : tau
  USE cell_base,        ONLY : alat, at, omega, bg
  USE cellmd,           ONLY : omega_old, at_old, calc
  USE force_mod,        ONLY : force
  USE ener,             ONLY : etot
  USE f90sockets,       ONLY : readbuffer, writebuffer
  USE extrapolation,    ONLY : update_file, update_pot
  USE io_files,         ONLY : iunupdate, nd_nmbr, prefix, tmp_dir, postfix, &
                               wfc_dir, delete_if_present, seqopn
  !
  IMPLICIT NONE
  INTEGER, INTENT(OUT) :: exit_status
  !! Gives the exit status at the end
  CHARACTER(*), INTENT(IN) :: srvaddress
  !! Gives the socket address 
  !
  ! Local variables
  INTEGER, PARAMETER :: MSGLEN=12
  REAL*8, PARAMETER :: gvec_omega_tol=1.0D-1
  LOGICAL :: isinit=.false., hasdata=.false., exst, firststep
  CHARACTER*12 :: header
  CHARACTER*1024 :: parbuffer
  INTEGER :: socket, nat, rid, ccmd, i, info, rid_old=-1
  REAL*8 :: sigma(3,3), omega_reset, at_reset(3,3), dist_reset, ang_reset
  REAL *8 :: cellh(3,3), cellih(3,3), vir(3,3), pot, mtxbuffer(9)
  REAL*8, ALLOCATABLE :: combuf(:)
  REAL*8 :: dist_ang(6), dist_ang_reset(6)
  !----------------------------------------------------------------------------
  !
  lscf      = .true.
  lforce    = .true.
  lstres    = .true.
  lmd       = .true.
  lmovecell = .true.
  firststep = .true.
  omega_reset = 0.d0
  !
  exit_status = 0
  IF ( ionode ) WRITE( unit = stdout, FMT = 9010 ) ntypx, npk, lmaxx
  !
  IF (ionode) CALL plugin_arguments()
  CALL plugin_arguments_bcast( ionode_id, intra_image_comm )
  !
  ! ... needs to come before iosys() so some input flags can be
  !     overridden without needing to write PWscf specific code.
  !
  ! ... convert to internal variables
  !
  CALL iosys()
  !
  IF ( gamma_only ) WRITE( UNIT = stdout, &
       & FMT = '(/,5X,"gamma-point specific algorithms are used")' )
  !
  ! call to void routine for user defined / plugin patches initializations
  !
  CALL plugin_initialization()
  !
  CALL check_stop_init()
  CALL setup()
  ! ... Initializations
  CALL init_run()
  IF (ionode) CALL create_socket(srvaddress)
  !
  driver_loop: DO
     !
     IF ( ionode ) CALL readbuffer(socket, header, MSGLEN)
     CALL mp_bcast( header, ionode_id, intra_image_comm )
     !
     IF ( ionode ) write(*,*) " @ DRIVER MODE: Message from server: ", trim( header )
     !
     SELECT CASE ( trim( header ) )
     CASE( "STATUS" )
        !
        IF (ionode) THEN  
           IF (hasdata) THEN
              CALL writebuffer( socket, "HAVEDATA    ", MSGLEN )
           ELSE IF (isinit) THEN
              CALL writebuffer( socket, "READY       ", MSGLEN )
           ELSE IF (.not. isinit) THEN
              CALL writebuffer( socket, "NEEDINIT    ", MSGLEN )
           ELSE
              exit_status = 129
              RETURN
           END IF
        END IF
        !
     CASE( "INIT" )
        CALL driver_init()
        isinit=.true.
        !
     CASE( "POSDATA" )
        CALL driver_posdata()
        hasdata=.true.
        !
     CASE( "GETFORCE" )
        CALL driver_getforce()
        !
        ! ... resets init to get replica index again at next step
        !
        isinit = .false.
        hasdata=.false.
        !
     CASE DEFAULT
        exit_status = 130
        RETURN
     END SELECT
     !
  END DO driver_loop
  !
9010 FORMAT( /,5X,'Current dimensions of program PWSCF are:', &
          & /,5X,'Max number of different atomic species (ntypx) = ',I2,&
          & /,5X,'Max number of k-points (npk) = ',I6,&
          & /,5X,'Max angular momentum in pseudopotentials (lmaxx) = ',i2)
  !
CONTAINS
  !
  !
  SUBROUTINE create_socket (srvaddress)
    USE f90sockets,       ONLY : open_socket 
    IMPLICIT NONE
    CHARACTER(*), INTENT(IN)  :: srvaddress
    CHARACTER(256) :: address
    INTEGER :: port, inet, field_sep_pos
    !
    ! ... Parses host name, port and socket type
    field_sep_pos = INDEX(srvaddress,':',back=.true.)
    address = srvaddress(1:field_sep_pos-1)
    !
    ! ... Check if UNIX type socket
    IF ( trim(srvaddress(field_sep_pos+1 :)) == 'UNIX' ) then
       port = 1234 ! place-holder
       inet = 0
       write(*,*) " @ DRIVER MODE: Connecting to ", trim(address), " using UNIX socket"
    ELSE
       read ( srvaddress ( field_sep_pos+1 : ), * ) port
       inet = 1
       write(*,*) " @ DRIVER MODE: Connecting to ", trim ( address ), &
                  ":", srvaddress ( field_sep_pos+1 : )
    END IF
    !
    ! ... Create the socket
    CALL open_socket ( socket, inet, port, trim(address)//achar(0) )
    !
  END SUBROUTINE create_socket
  !
  !
  SUBROUTINE driver_init()
    !
    ! ... Check if the replica id (rid) is the same as in the last run
    !
    IF ( ionode ) CALL readbuffer( socket, rid ) 
    CALL mp_bcast( rid, ionode_id, intra_image_comm )
    !
    IF ( ionode ) WRITE(*,*) " @ DRIVER MODE: Receiving replica", rid, rid_old
    IF ( rid .NE. rid_old ) THEN
       !
       ! ... If a different replica reset the history
       !
       CALL reset_history_for_extrapolation()
    END IF
    !
    rid_old = rid
    !
    IF ( ionode ) THEN
       !
       ! ... Length of parameter string -- ignored at present!
       !
       CALL readbuffer( socket, nat ) 
       CALL readbuffer( socket, parbuffer, nat )
    END IF
    !
  END SUBROUTINE driver_init
  !
  !
  SUBROUTINE driver_posdata()
    !
    ! ... Receives the positions & the cell data
    !
    at_old = at
    omega_old = omega
    !
    ! ... Read the atomic position from ipi and share to all processes
    !
    CALL read_and_share()
    !
    IF ( ionode ) WRITE(*,*) " @ DRIVER MODE: Received positions "
    !
    ! ... Recompute cell data
    !
    CALL recips( at(1,1), at(1,2), at(1,3), bg(1,1), bg(1,2), bg(1,3) )
    CALL volume( alat, at(1,1), at(1,2), at(1,3), omega )
    !
    ! ... If the cell is changes too much, reinitialize G-Vectors
    ! ... also extrapolation history must be reset
    ! ... If firststep, it will also be executed (omega_reset equals 0),
    ! ... to make sure we initialize G-vectors using positions from I-PI
        IF ( ((ABS( omega_reset - omega ) / omega) .GT. gvec_omega_tol) .AND. (gvec_omega_tol .GE. 0.d0) ) THEN
           IF (ionode) THEN
               IF (firststep) THEN
                   WRITE(*,*) " @ DRIVER MODE: initialize G-vectors "
               ELSE
                   WRITE(*,*) " @ DRIVER MODE: reinitialize G-vectors "
               END IF
           END IF
           CALL initialize_g_vectors()
           CALL reset_history_for_extrapolation()
           !
        ELSE
           !
           ! ... Update only atomic position and potential from the history
           ! ... if the cell did not change too much
           !
           IF (.NOT. firststep) THEN
               CALL update_pot()
               CALL hinit1()
           END IF
        END IF
    firststep = .false.
    !
    ! ... Compute everything
    !
    CALL electrons()
    IF ( .NOT. conv_elec ) THEN
       CALL punch( 'all' )
       CALL stop_run( conv_elec )
    ENDIF
    CALL forces()
    CALL stress(sigma)
    !
    ! ... Converts energy & forces to the format expected by i-pi
    ! ... (so go from Ry to Ha)
    !
    combuf=RESHAPE(force, (/ 3 * nat /) ) * 0.5   ! force in a.u.
    pot=etot * 0.5                                ! potential in a.u.
    vir=TRANSPOSE( sigma ) * omega * 0.5          ! virial in a.u & no omega scal.
    !
    ! ... Updates history
    !
    istep = istep+1
    CALL update_file()
    !
  END SUBROUTINE driver_posdata
  !
  !
  SUBROUTINE driver_getforce()
    !
    ! ... communicates energy info back to i-pi
    !
    IF ( ionode ) WRITE(*,*) " @ DRIVER MODE: Returning v,forces,stress "
    IF ( ionode ) CALL writebuffer( socket, "FORCEREADY  ", MSGLEN)         
    IF ( ionode ) CALL writebuffer( socket, pot)
    IF ( ionode ) CALL writebuffer( socket, nat)
    IF ( ionode ) CALL writebuffer( socket, combuf, 3 * nat)
    IF ( ionode ) CALL writebuffer( socket, RESHAPE( vir, (/9/) ), 9)
    !
    ! ... Note: i-pi can also receive an arbitrary string, that will be printed
    ! ... out to the "extra" trajectory file. This is useful if you want to
    ! ... return additional information, e.g. atomic charges, wannier centres,
    ! ... etc. one must return the number of characters, then the string. Here
    ! .... we just send back zero characters.
    !
    nat = 0
    IF ( ionode ) CALL writebuffer( socket, nat )
    CALL punch( 'config' )
    !
  END SUBROUTINE driver_getforce
  !
  !
  SUBROUTINE read_and_share()
    ! ... First reads cell and the number of atoms
    !
    IF ( ionode ) CALL readbuffer(socket, mtxbuffer, 9)
    cellh = RESHAPE(mtxbuffer, (/3,3/))         
    IF ( ionode ) CALL readbuffer(socket, mtxbuffer, 9)
    cellih = RESHAPE(mtxbuffer, (/3,3/))
    IF ( ionode ) CALL readbuffer(socket, nat)
    !
    ! ... Share the received data 
    !
    CALL mp_bcast( cellh,  ionode_id, intra_image_comm )  
    CALL mp_bcast( cellih, ionode_id, intra_image_comm )
    CALL mp_bcast(    nat, ionode_id, intra_image_comm )
    !
    ! ... Allocate the dummy array for the atoms coordinate and share it
    !
    IF ( .NOT. ALLOCATED( combuf ) ) THEN
       ALLOCATE( combuf( 3 * nat ) )
    END IF
    IF ( ionode ) CALL readbuffer(socket, combuf, nat*3)
    CALL mp_bcast( combuf, ionode_id, intra_image_comm)
    !
    ! ... Convert the incoming configuration to the internal pwscf format
    !
    cellh  = TRANSPOSE(  cellh )                 ! row-major to column-major 
    cellih = TRANSPOSE( cellih )         
    tau = RESHAPE( combuf, (/ 3 , nat /) )/alat  ! internally positions are in alat 
    at = cellh / alat                            ! and so the cell
    !
  END SUBROUTINE read_and_share
  !
  !
  SUBROUTINE initialize_g_vectors()
    !
    CALL clean_pw( .FALSE. )
    CALL init_run()
    !
    CALL mp_bcast( at,        ionode_id, intra_image_comm )
    CALL mp_bcast( at_old,    ionode_id, intra_image_comm )
    CALL mp_bcast( omega,     ionode_id, intra_image_comm )
    CALL mp_bcast( omega_old, ionode_id, intra_image_comm )
    CALL mp_bcast( bg,        ionode_id, intra_image_comm )
    !
    omega_reset = omega
    dist_ang_reset = dist_ang
    !
  END SUBROUTINE initialize_g_vectors
  !
  SUBROUTINE reset_history_for_extrapolation()
    !
    ! ... Resets history of wavefunction and rho as if the
    ! ... previous step was the first one in the calculation.
    ! ... To this end, files with rho and wfc from previous steps
    ! ... must be deleted, and iunupdate unit wiped. The latter
    ! ... is achieved by deleting the file and recreating it using
    ! ... update_file() routine.
    !
    IMPLICIT NONE
    LOGICAL :: exst
    !
    ! ... Delete history files, names correspond to the ones
    ! ... in the update_pot() routine.
    !
    CALL delete_if_present(TRIM( wfc_dir ) // TRIM( prefix ) // '.oldwfc' // nd_nmbr)
    CALL delete_if_present(TRIM( wfc_dir ) // TRIM( prefix ) // '.old2wfc' // nd_nmbr)
    IF ( ionode ) THEN
       CALL delete_if_present(TRIM( tmp_dir ) // TRIM( prefix ) // postfix // 'charge-density.old.dat')
       CALL delete_if_present(TRIM( tmp_dir ) // TRIM( prefix ) // postfix // 'charge-density.old2.dat')
       !
       ! ... The easiest way to wipe the iunupdate unit, is to delete it
       ! ... and run update_file(), which will recreate the file
       !
       CALL seqopn( iunupdate, 'update', 'FORMATTED', exst )
       CLOSE(UNIT=iunupdate, STATUS='DELETE')
    END IF
    !
    CALL update_file()
    !
  END SUBROUTINE
!
END SUBROUTINE run_driver

FUNCTION get_server_address ( command_line ) RESULT ( srvaddress )
  ! 
  ! checks for the presence of a command-line option of the form
  ! -server_ip "srvaddress" or --server_ip "srvaddress";
  ! returns "srvaddress", used to run pw.x in driver mode.
  ! On input, "command_line" must contain the unprocessed part of the command
  ! line, on all processors, as returned after a call to "get_cammand_line"
  !
  USE command_line_options, ONLY : my_iargc, my_getarg
  IMPLICIT NONE
  CHARACTER(LEN=*), INTENT(IN) :: command_line
  CHARACTER(LEN=256) :: srvaddress
  !
  INTEGER  :: nargs, narg
  CHARACTER (len=320) :: arg
  !
  srvaddress = ' '
  IF ( command_line == ' ' ) RETURN
  !
  nargs = my_iargc ( command_line )
  !
  narg = 0
10 CONTINUE
  CALL my_getarg ( command_line, narg, arg )
  IF ( TRIM (arg) == '-ipi' .OR. TRIM (arg) == '--ipi' ) THEN
     IF ( srvaddress == ' ' ) THEN
        narg = narg + 1
        IF ( narg > nargs ) THEN
           CALL infomsg('get_server_address','missing server IP in command line')
           RETURN
        ELSE
           CALL my_getarg ( command_line, narg, srvaddress )
        END IF
     ELSE
        CALL infomsg('get_server_address','duplicated server IP in command line')
     END IF
  END IF
  narg = narg + 1
  IF ( narg > nargs ) RETURN
  GO TO 10
  !
END FUNCTION get_server_address
