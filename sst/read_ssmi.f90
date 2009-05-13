subroutine read_ssmi(mype,val_ssmi,ithin,rmesh,jsatid,gstime,&
     infile,lunout,obstype,nread,ndata,nodata,twind,sis,&
     mype_root,mype_sub,npe_sub,mpi_comm_sub)

!$$$  subprogram documentation block
! subprogram:    read_ssmi           read SSM/I  bufr1b data
!   prgmmr: okamoto          org: np23                date: 2003-12-27
!
! abstract:  This routine reads BUFR format SSM/I 1b radiance 
!            (brightness temperature) files.  Optionally, the data 
!            are thinned to a specified resolution using simple 
!            quality control (QC) checks.
!            QC performed in this subroutine are
!             1.obs time check  |obs-anal|<time_window
!             2.remove overlap orbit
!             3.climate check  reject for tb<tbmin or tb>tbmax 
!
!            When running the gsi in regional mode, the code only
!            retains those observations that fall within the regional
!            domain
!
! program history log:
!   2003-12-27 okamoto
!   2005-09-08  derber - modify to use input group time window
!   2005-09-28  derber - modify to produce consistent surface info - clean up
!   2005-10-17  treadon - add grid and earth relative obs location to output file
!   2005-10-18  treadon - remove array obs_load and call to sumload
!   2005-11-29  parrish - modify getsfc to work for different regional options
!   2006-02-01  parrish - remove getsfc, refs to sno,sli,sst,isli (not used)
!   2006-02-03  derber  - modify for new obs control and obs count
!   2006-03-07  derber - correct error in nodata count
!   2006-04-27  derber - some efficiency modifications
!   2006-05-19  eliu    - add logic to reset relative weight when all channels not used
!   2006-07-28  derber  - add solar and satellite azimuth angles remove isflg from output
!   2006-08-25  treadon - replace serial bufr i/o with parallel bufr i/o (mpi_io)
!   2006-12-20  Sienkiewicz - add additional satellites f08 f10 f11
!                             set satellite zenith angle (avail. in Wentz data)
!                             85GHz workaround for f08
!   2007-03-01  Tremolet - tdiff definition had disappeared somehow
!   2007-03-01  tremolet - measure time from beginning of assimilation window
!   2007-04-24  derber - define tdiff (was undefined)
!   2008-04-17  safford - rm unused vars
!   2009-04-18  woollen - improve mpi_io interface with bufrlib routines
!   2009-04-21  derber  - add ithin to call to makegrids
!
!   input argument list:
!     mype     - mpi task id
!     val_ssmi - weighting factor applied to super obs
!     ithin    - flag to thin data
!     rmesh    - thinning mesh size (km)
!     jsatid   - satellite to read  ex. 'f15'
!     gstime   - analysis time in minutes from reference date
!     infile   - unit from which to read BUFR data
!     lunout   - unit to which to write data for further processing
!     obstype  - observation type to process
!     twind    - input group time window (hours)
!     sis      - satellite/instrument/sensor indicator
!     mype_root - "root" task for sub-communicator
!     mype_sub - mpi task id within sub-communicator
!     npe_sub  - number of data read tasks
!     mpi_comm_sub - sub-communicator for data read
!
!   output argument list:
!     nread    - number of BUFR SSM/I observations read (after eliminating orbit overlap)
!     ndata    - number of BUFR SSM/I profiles retained for further processing (thinned)
!     nodata   - number of BUFR SSM/I observations retained for further processing (thinned)
!
! attributes:
!   language: f90
!   machine:  ibm RS/6000 SP
!
!$$$  end documentation block
  use kinds, only: r_kind,r_double,i_kind
  use satthin, only: super_val,itxmax,makegrids,map2tgrid,destroygrids, &
            checkob,finalcheck,score_crit
  use radinfo, only: iuse_rad,jpch_rad,nusis,nuchan
  use gridmod, only: diagnostic_reg,regional,rlats,rlons,nlat,nlon,&
       tll2xy,txy2ll
  use constants, only: deg2rad,rad2deg,zero,one,two,three,four
  use obsmod, only: iadate,offtime_data
  use gsi_4dvar, only: iadatebgn,iadateend,l4dvar,idmodel,iwinbgn,winlen
  use mpi_bufr_mod, only: mpi_openbf,mpi_closbf,mpi_nextblock,mpi_readmg

  implicit none

! Declare passed variables
  character(10),intent(in):: infile,obstype,jsatid
  character(20),intent(in):: sis
  integer(i_kind),intent(in)      :: mype,lunout,ithin
  integer(i_kind)  ,intent(in) :: mype_root
  integer(i_kind)  ,intent(in) :: mype_sub
  integer(i_kind)  ,intent(in) :: npe_sub
  integer(i_kind)  ,intent(in) :: mpi_comm_sub
  real(r_kind),intent(in) :: rmesh,gstime,twind
  real(r_kind),intent(inout):: val_ssmi

  integer(i_kind),intent(inout):: nread

  integer(i_kind),intent(inout):: ndata,nodata


! Declare local parameters
  integer(i_kind),parameter :: n1bhdr=14
  integer(i_kind),parameter :: maxinfo=33
  integer(i_kind),parameter :: maxchanl=30

  integer(i_kind),parameter :: ntime=8      !time header
  integer(i_kind),parameter :: nloc=5       !location dat used for ufbint()
  integer(i_kind),parameter :: maxscan=64   !possible max of scan positons
  real(r_kind),parameter:: r360=360.0_r_kind
  real(r_kind),parameter:: tbmin=70.0_r_kind
  real(r_kind),parameter:: tbmax=320.0_r_kind
  real(r_kind),parameter:: tbbad=-9.99e11_r_kind
  character(80),parameter:: hdr1b='SAID YEAR MNTH DAYS HOUR MINU SECO ORBN'   !use for ufbint()
  character(40),parameter:: str1='CLAT CLON SFTG POSN SAZA'   !use for ufbint()
  character(40),parameter:: str2='TMBR'                  !use for ufbrep()

! Declare local variables
  logical ssmi,assim
  logical outside,iuse

  character(10) date
  character(8) subset,subfgn

  integer ihh,i,k,idd,isc,ntest,ireadsb
  integer iret,idate,im,iy,nchanl
  integer isflg,nreal,idomsfc
  integer nmind,itx,nele,itt,iout
  integer iskip
  integer lnbufr
  integer ilat,ilon

  real(r_kind) sfcr

  real(r_kind) pred
  real(r_kind) sstime,tdiff,t4dv
  real(r_kind) crit1,dist1
  real(r_kind) timedif
  real(r_kind),allocatable,dimension(:,:):: data_all
  integer(i_kind):: mmblocks
  integer(i_kind):: isubset

  real(r_kind) disterr,disterrmax,dlon00,dlat00

!  ---- bufr argument -----
  real(r_double),dimension(n1bhdr):: bfr1bhdr
  real(r_double),dimension(nloc,maxscan) :: midat  !location data from str1
  real(r_double),dimension(maxchanl*maxscan) :: mirad !TBB from str2



  integer(i_kind) :: nscan,jc,bufsat,js,ij,npos,n
  integer(i_kind),dimension(5):: iobsdate
  integer(i_kind):: file_handle,ierror,nblocks
  real(r_kind):: tb19v,tb22v,tb85v,si85,flgch,q19
  real(r_kind),dimension(maxchanl):: tbob
  real(r_kind),dimension(0:3):: sfcpct
  real(r_kind),dimension(0:3):: ts
  real(r_kind),dimension(0:4):: rlndsea
  real(r_kind) :: tsavg,vty,vfr,sty,stp,sm,sn,zz,ff10

  real(r_kind):: oneover60
  real(r_kind):: dlat,dlon,dlon_earth,dlat_earth
  real(r_kind):: ssmi_def_ang,ssmi_zen_ang  ! default and obs SSM/I zenith ang
  logical  do85GHz, ch6, ch7
  real(r_kind):: bmiss=10.e10

!**************************************************************************
! Initialize variables
  lnbufr = 15
  disterrmax=zero
  ntest=0
  nreal  = maxinfo
  nchanl = 30
  ndata  = 0
  nodata  = 0
  nread  = 0
  oneover60 = one/60._r_kind
  ssmi_def_ang = 53.1_r_kind

  ilon=3
  ilat=4

! Set various variables depending on type of data to be read

  ssmi  = obstype  == 'ssmi'

  if ( ssmi ) then
     nscan  = 64   !for A-scan
!    nscan  = 128  !for B-scan
     nchanl = 7
     subfgn = 'NC012001'
     if(jsatid == 'f08')bufsat=241
     if(jsatid == 'f10')bufsat=243
     if(jsatid == 'f11')bufsat=244
     if(jsatid == 'f13')bufsat=246
     if(jsatid == 'f14')bufsat=247
     if(jsatid == 'f15')bufsat=248
     rlndsea(0) = zero
     rlndsea(1) = 30._r_kind
     rlndsea(2) = 30._r_kind
     rlndsea(3) = 30._r_kind
     rlndsea(4) = 100._r_kind
  end if

! If all channels of a given sensor are set to monitor or not
! assimilate mode (iuse_rad<1), reset relative weight to zero.
! We do not want such observations affecting the relative
! weighting between observations within a given thinning group.

  assim=.false.
  ch6=.false.
  ch7=.false.
  search: do i=1,jpch_rad
     if (nusis(i)==sis) then
	if (iuse_rad(i)>=0) then
           if (iuse_rad(i)>0) assim=.true.
	   if (nuchan(i)==6) ch6=.true.
	   if (nuchan(i)==7) ch7=.true.
	   if (assim.and.ch6.and.ch7) exit
	endif
     endif
  end do search
  if (.not.assim) val_ssmi=zero

  do85GHz = .not. assim .or. (ch6.and.ch7)

! Make thinning grids
  call makegrids(rmesh,ithin)

! Open unit to satellite bufr file
  open(lnbufr,file=infile,form='unformatted')
  call openbf(lnbufr,'IN',lnbufr)
  call datelen(10)
  call readmg(lnbufr,subset,idate,iret)
  close(lnbufr)  ! this enables reading with mpi i/o
  if( subset /= subfgn) then
     write(6,*) 'READ_SSMI:  *** WARNING: ',&
          'THE FILE TITLE NOT MATCH DATA SUBSET'
     write(6,*) '  infile=', lnbufr, infile,' subset=',&
          subset, ' subfgn=',subfgn
     write(6,*) 'SKIP PROCESSING OF THIS 1B FILE'
     go to 1000
  end if

  iy=0; im=0; idd=0; ihh=0
  write(date,'( i10)') idate
  read(date,'(i4,3i2)') iy,im,idd,ihh
  if (mype_sub==mype_root) &
       write(6,*) 'READ_SSMI: bufr file data is ',iy,im,idd,ihh,infile
  if(im/=iadate(2).or.idd/=iadate(3)) then
     if(offtime_data) then
       write(6,*)'***READ_SSMI analysis and data file date differ, but use anyway'
     else
       write(6,*)'***READ_SSMI ERROR*** ',&
          'incompatable analysis and observation date/time'
     end if
     write(6,*)' year  anal/obs ',iadate(1),iy
     write(6,*)' month anal/obs ',iadate(2),im
     write(6,*)' day   anal/obs ',iadate(3),idd
     write(6,*)' hour  anal/obs ',iadate(4),ihh
     if(.not.offtime_data) go to 1000
  end if



! Allocate arrays to hold data
  nele=nreal+nchanl
  allocate(data_all(nele,itxmax))


! Open up bufr file for mpi-io access
  call mpi_openbf(infile,npe_sub,mype_sub,mpi_comm_sub,file_handle,ierror,nblocks)

! Big loop to read data file
  mpi_loop: do mmblocks=0,nblocks-1,npe_sub
     if(mmblocks+mype_sub.gt.nblocks-1) then
        exit
     endif
     call mpi_nextblock(mmblocks+mype_sub,file_handle,ierror)
     block_loop: do
        call mpi_readmg(lnbufr,subset,idate,iret)
        if (iret /=0) exit
        read(subset,'(2x,i6)')isubset
        read_loop: do while (ireadsb(lnbufr)==0)


! ----- Read header record to extract satid,time information  
!       SSM/I data are stored in groups of nscan, hence the loop.  
        call ufbint(lnbufr,bfr1bhdr,ntime,1,iret,hdr1b)

!       Extract satellite id.  If not the one we want, read next record
        if(bfr1bhdr(1) /= bufsat) cycle read_loop


!       calc obs seqential time  If time outside window, skip this obs
        iobsdate(1:5) = bfr1bhdr(2:6) !year,month,day,hour,min
        isc           = bfr1bhdr(7) !second
        call w3fs21(iobsdate,nmind)
        t4dv=(real(nmind-iwinbgn,r_kind) + real(isc,r_kind)*oneover60)*oneover60
        if (l4dvar) then
          if (t4dv<zero .OR. t4dv>winlen) cycle read_loop
        else
          sstime=real(nmind,r_kind) + real(isc,r_kind)*oneover60
          tdiff=(sstime-gstime)*oneover60
          if(abs(tdiff) > twind)  cycle read_loop
        endif

! ----- Read header record to extract obs location information  
!       SSM/I data are stored in groups of nscan, hence the loop.  

        call ufbint(lnbufr,midat,nloc,nscan,iret,str1)


!---    Extract brightness temperature data.  Apply gross check to data. 
!       If obs fails gross check, reset to missing obs value.

        call ufbrep(lnbufr,mirad,1,nchanl*nscan,iret,str2)


        ij=0
        scan_loop:   do js=1,nscan


!         Regional case
          dlat_earth = midat(1,js)  !deg
          dlon_earth = midat(2,js)  !deg
          if(dlon_earth< zero) dlon_earth = dlon_earth+r360
          if(dlon_earth>=r360) dlon_earth = dlon_earth-r360
          dlat_earth = dlat_earth*deg2rad
          dlon_earth = dlon_earth*deg2rad

          if(regional)then
             call tll2xy(dlon_earth,dlat_earth,dlon,dlat,outside)
             if(diagnostic_reg) then
                call txy2ll(dlon,dlat,dlon00,dlat00)
                ntest=ntest+1
                disterr=acos(sin(dlat_earth)*sin(dlat00)+cos(dlat_earth)*cos(dlat00)* &
                     (sin(dlon_earth)*sin(dlon00)+cos(dlon_earth)*cos(dlon00)))*rad2deg
                disterrmax=max(disterrmax,disterr)
             end if

!            Check to see if in domain
             if(outside) cycle read_loop

!         Global case
          else
             dlat = dlat_earth  
             dlon = dlon_earth  
             call grdcrd(dlat,1,rlats,nlat,1)
             call grdcrd(dlon,1,rlons,nlon,1)
          endif

!  If available, set value of ssmi zenith angle
!
          if (midat(5,js) < bmiss ) then
             ssmi_zen_ang = midat(5,js)
          else
             ssmi_zen_ang = ssmi_def_ang
          endif

        
!         Transfer observed brightness temperature to work array.  
!         If any temperature exceeds limits, reset observation to "bad" value
!         mirad(1:maxchanl*nscan) => data1b(1:6+nchanl)
          iskip=0
          do jc=1,nchanl
             ij = ij+1
             if(mirad(ij)<tbmin .or. mirad(ij)>tbmax ) then
                mirad(ij) = tbbad
                iskip = iskip + 1
                if(jc == 1 .or. jc == 3 .or. jc == 6)iskip=iskip+nchanl
             else
                nread=nread+1
             end if
             tbob(jc) = mirad(ij) 
  
          end do   !jc_loop
          if(iskip >= nchanl)  cycle scan_loop  !if all ch for any position is bad, skip 
          flgch = iskip*two   !used for thinning priority range 0-14

          if (l4dvar) then
            crit1 = 0.01_r_kind+ flgch
          else
            timedif = 6.0_r_kind*abs(tdiff) ! range: 0 to 18
            crit1 = 0.01_r_kind+timedif + flgch
          endif
!         Map obs to thinning grid
          call map2tgrid(dlat_earth,dlon_earth,dist1,crit1,itx,ithin,itt,iuse,sis)
          if(.not. iuse)cycle scan_loop


!         Locate the observation on the analysis grid.  Get sst and land/sea/ice
!         mask.  

!       isflg    - surface flag
!                  0 sea
!                  1 land
!                  2 sea ice
!                  3 snow
!                  4 mixed                     

         call deter_sfc_type(dlat_earth,dlon_earth,t4dv,isflg,tsavg)
  
          crit1 = crit1 + rlndsea(isflg)
          call checkob(dist1,crit1,itx,iuse)
          if(.not. iuse)cycle scan_loop

       if (do85GHz) then  ! do regular checks if 85 GHz available
  
!    ---- Set data quality predictor for initial qc -------------
!      -  simple si index : taken out from ssmiqc()
!            note! it exclude emission rain
          tb19v=tbob(1);  tb22v=tbob(3); tb85v=tbob(6)
          if(isflg/=0)  then !land+snow+ice
            si85 = 451.9_r_kind - 0.44_r_kind*tb19v - 1.775_r_kind*tb22v + &
               0.00574_r_kind*tb22v*tb22v - tb85v
          else    !sea
            si85 = -174.4_r_kind + 0.715_r_kind*tb19v + 2.439_r_kind*tb22v -  &
                 0.00504_r_kind*tb22v*tb22v - tb85v
          end if

!         Compute "score" for observation.  All scores>=0.0.  Lowest score is "best"
          pred = abs(si85)*three  !range: 0 to 30

       else              ! otherwise do alternate check for rain

          if (isflg/=0) then     ! just try to scren out land pts.
             pred = 30
          else
             tb19v=tbob(1);  tb22v=tbob(3);
             if (tb19v < 288.0_r_kind .and. tb22v < 288.0_r_kind) then
                q19 = -6.723_r_kind * ( log(290.0_r_kind - tb19v)  &
                     - 2.850_r_kind - 0.405_r_kind* log(290.0_r_kind - tb22v))
                pred = 75._r_kind * q19  ! scale 0.4mm -> pred ~ 30
             endif
          endif
       endif

!         Compute final "score" for observation.  All scores>=0.0.  
!         Lowest score is "best"
          crit1 = crit1 + pred 

          call finalcheck(dist1,crit1,itx,iuse)
          if(.not. iuse)cycle scan_loop

          npos = (midat(4,js)-one)/four+one !original scan position 1.0->253.0 =4*(n-1)+1

!         Transfer observation parameters to output array.  
          data_all( 1,itx) = bufsat              !satellite id
          data_all( 2,itx) = t4dv                !time diff between obs and anal (min)
          data_all( 3,itx) = dlon                !grid relative longitude
          data_all( 4,itx) = dlat                !grid relative latitude
          data_all( 5,itx) = ssmi_zen_ang*deg2rad !local zenith angle (rad)
          data_all( 6,itx) = 999.00              !local azimuth angle (missing)
          data_all( 7,itx) = zero                !look angle (rad)
!+>       data_all( 7,itx) =  45.0*deg2rad       !look angle (rad)
          data_all( 8,itx) = npos                !scan position 1->64
          data_all( 9,itx) = zero                !solar zenith angle (deg) : not used
          data_all(10,itx) = 999.00              !solar azimuth angle (missing) : not used

          data_all(30,itx)= dlon_earth           ! earth relative longitude (degrees)
          data_all(31,itx)= dlat_earth           ! earth relative latitude (degrees)

          data_all(nreal-1,itx)=val_ssmi
          data_all(nreal,itx)=itt

          do i=1,nchanl
             data_all(i+nreal,itx)=tbob(i)
          end do

        end do  scan_loop    !js_loop end

     end do read_loop
  end do block_loop
end do mpi_loop

  write(6,*) 'READ_SSMI: at end of mpi_loop, nread is ',nread

  write(6,*) 'READ_SSMI: at end of mpi_loop ',mype,mype_sub,mype_root,npe_sub,nele, &
         itxmax,ndata
! If multiple tasks read input bufr file, allow each tasks to write out
! information it retained and then let single task merge files together

! Close bufr file
  call mpi_closbf(file_handle,ierror)
  call closbf(lnbufr)

  call combine_radobs(mype,mype_sub,mype_root,npe_sub,mpi_comm_sub,&
       nele,itxmax,nread,ndata,data_all,score_crit)

  write(6,*) 'READ_SSMI: after combine_obs, nread,ndata is ',nread,ndata

! Allow single task to check for bad obs, update superobs sum,
! and write out data to scratch file for further processing.
  if (mype_sub==mype_root) then

!    Identify "bad" observation (unreasonable brightness temperatures).
!    Update superobs sum according to observation location

     do n=1,ndata
        do i=1,nchanl
           if(data_all(i+nreal,n) > tbmin .and. &
                data_all(i+nreal,n) < tbmax)nodata=nodata+1
        end do
        itt=nint(data_all(nreal,n))
        super_val(itt)=super_val(itt)+val_ssmi
        tdiff = data_all(2,n)                ! time (hours)
        dlon=data_all(3,n)                   ! grid relative longitude
        dlat=data_all(4,n)                   ! grid relative latitude
        dlon_earth = data_all(30,n)  ! earth relative longitude (degrees)
        dlat_earth = data_all(31,n)  ! earth relative latitude (degrees)

        call deter_sfc(dlat,dlon,dlat_earth,dlon_earth,tdiff,isflg,idomsfc,sfcpct, &
            ts,tsavg,vty,vfr,sty,stp,sm,sn,zz,ff10,sfcr)
        data_all(11,n) = sfcpct(0)           ! sea percentage of
        data_all(12,n) = sfcpct(1)           ! land percentage
        data_all(13,n) = sfcpct(2)           ! sea ice percentage
        data_all(14,n) = sfcpct(3)           ! snow percentage
        data_all(15,n)= ts(0)                ! ocean skin temperature
        data_all(16,n)= ts(1)                ! land skin temperature
        data_all(17,n)= ts(2)                ! ice skin temperature
        data_all(18,n)= ts(3)                ! snow skin temperature
        data_all(19,n)= tsavg                ! average skin temperature
        data_all(20,n)= vty                  ! vegetation type
        data_all(21,n)= vfr                  ! vegetation fraction
        data_all(22,n)= sty                  ! soil type
        data_all(23,n)= stp                  ! soil temperature
        data_all(24,n)= sm                   ! soil moisture
        data_all(25,n)= sn                   ! snow depth
        data_all(26,n)= zz                   ! surface height
        data_all(27,n)= idomsfc + 0.001      ! dominate surface type
        data_all(28,n)= sfcr                 ! surface roughness
        data_all(29,n)= ff10                 ! ten meter wind factor
        data_all(30,n)= data_all(30,n)*rad2deg  ! earth relative longitude (degrees)
        data_all(31,n)= data_all(31,n)*rad2deg  ! earth relative latitude (degrees)

     end do

!    Write final set of "best" observations to output file
     write(lunout) obstype,sis,nreal,nchanl,ilat,ilon
     write(lunout) ((data_all(k,n),k=1,nele),n=1,ndata)
  
  endif

! Deallocate data arrays
  deallocate(data_all)


! Deallocate satthin arrays
1000 continue
  call destroygrids

  if(diagnostic_reg .and. ntest>0 .and. mype_sub==mype_root) &
       write(6,*)'READ_SSMI:  mype,ntest,disterrmax=',&
       mype,ntest,disterrmax


! End of routine
 return
end subroutine read_ssmi
