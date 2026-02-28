# archlinux-install
- To run this script, do the following from the live arch iso:

  1. Install wget which will be used to run the script:
     
  ```bash
  pacman -Sy wget
  ```

  2. Run the script:
 
  ```
  wget -qO- https://raw.githubusercontent.com/FatihTheDev/archlinux-install/main/installation.sh | bash
  ```

  **Note**: This is a capital letter o, not a zero.

  3. Wait for the script to finish, then run `poweroff`.
 
  4. Pull out the USB that has the .iso file out of the computer
 
  5. Power your computer back on.
 
  6. That's it! You should be presented with your new Telva Linux environment.
     


**Disclaimer**: To later enable virtual network 'default', run this command in terminal:

```bash
sudo virsh net-autostart default
```
